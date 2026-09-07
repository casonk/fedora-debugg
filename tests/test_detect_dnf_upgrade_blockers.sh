#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
if [ "${KEEP_TMP:-0}" != "1" ]; then
  trap 'rm -rf "${TMP_DIR}"' EXIT
fi

MOCK_BIN="${TMP_DIR}/mock-bin"
mkdir -p "${MOCK_BIN}"

cat >"${MOCK_BIN}/dnf-clean" <<'EOF'
#!/usr/bin/env bash
echo "Repositories loaded."
echo "Nothing to do."
exit 0
EOF
chmod +x "${MOCK_BIN}/dnf-clean"

cat >"${MOCK_BIN}/dnf-blocked" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
Problem: installed package ttyd-1.7.7-7.fc43.x86_64 requires libwebsockets.so.20()(64bit), but none of the providers can be installed
  - cannot install both libwebsockets-4.5.8-2.fc43.x86_64 from updates and libwebsockets-4.4.4-1.fc43.x86_64 from @System
  - cannot install the best update candidate for package ttyd-1.7.7-7.fc43.x86_64
OUT
exit 1
EOF
chmod +x "${MOCK_BIN}/dnf-blocked"

cat >"${MOCK_BIN}/rpm-stub" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-q" ] && [ "${2:-}" = "--whatprovides" ]; then
  echo "libwebsockets-4.4.4-1.fc43.x86_64"
  exit 0
fi
if [ "${1:-}" = "-q" ] && [ "${2:-}" = "--qf" ]; then
  echo "libwebsockets"
  exit 0
fi
exit 1
EOF
chmod +x "${MOCK_BIN}/rpm-stub"

# Case 1: no blockers -> exit 0, report says so.
clean_output="$(
  "${ROOT_DIR}/scripts/detect_dnf_upgrade_blockers.sh" \
    --dnf "${MOCK_BIN}/dnf-clean" --rpm "${MOCK_BIN}/rpm-stub"
)"
clean_status=$?
printf '%s\n' "${clean_output}" >"${TMP_DIR}/clean.txt"
[ "${clean_status}" -eq 0 ] || fail "expected exit 0 when no blockers are found"
assert_contains "${TMP_DIR}/clean.txt" "No soname-bump upgrade blockers detected."

# Case 2: a blocker -> exit 1, report identifies package/capability/provider.
blocked_status=0
blocked_output="$(
  "${ROOT_DIR}/scripts/detect_dnf_upgrade_blockers.sh" \
    --dnf "${MOCK_BIN}/dnf-blocked" --rpm "${MOCK_BIN}/rpm-stub" \
    --output "${TMP_DIR}/report.md"
)" || blocked_status=$?
printf '%s\n' "${blocked_output}" >"${TMP_DIR}/blocked.txt"
[ "${blocked_status}" -eq 1 ] || fail "expected exit 1 when a blocker is found"
assert_contains "${TMP_DIR}/blocked.txt" 'Blocked package: `ttyd-1.7.7-7.fc43.x86_64`'
assert_contains "${TMP_DIR}/blocked.txt" 'Missing capability: `libwebsockets.so.20()(64bit)`'
assert_contains "${TMP_DIR}/blocked.txt" 'Currently provided by: `libwebsockets-4.4.4-1.fc43.x86_64`'
assert_contains "${TMP_DIR}/blocked.txt" './scripts/generate_dnf_rebuild_fix.sh ttyd'
assert_file_exists "${TMP_DIR}/report.md"
assert_contains "${TMP_DIR}/report.md" 'Blocked package: `ttyd-1.7.7-7.fc43.x86_64`'

echo "OK"
