#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ALT_ROOT="${TMP_DIR}/root"
MOCK_BIN="${TMP_DIR}/mock-bin"
OUTPUT_FILE="${TMP_DIR}/output.txt"
mkdir -p "${ALT_ROOT}/usr/share/lynis/include" "${MOCK_BIN}"
touch "${ALT_ROOT}/usr/share/lynis/include/functions"

cat >"${MOCK_BIN}/dnf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${DNF_ARGS_FILE}"
EOF

cat >"${MOCK_BIN}/stat" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-c" ] && [ "\${2:-}" = "%u:%g" ]; then
  printf '65534:65534\n'
  exit 0
fi
exit 1
EOF

cat >"${MOCK_BIN}/chown" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${CHOWN_ARGS_FILE}"
EOF

chmod +x "${MOCK_BIN}"/*

DNF_ARGS_FILE="${TMP_DIR}/dnf-args.txt"
CHOWN_ARGS_FILE="${TMP_DIR}/chown-args.txt"

DNF_ARGS_FILE="${DNF_ARGS_FILE}" CHOWN_ARGS_FILE="${CHOWN_ARGS_FILE}" PATH="${MOCK_BIN}:${PATH}" \
  "${ROOT_DIR}/scripts/setup_security_tooling.sh" --root "${ALT_ROOT}" >"${OUTPUT_FILE}"

assert_contains "${OUTPUT_FILE}" "Installing packages: clamav clamav-update aide lynis openscap-scanner scap-security-guide audit"
assert_contains "${OUTPUT_FILE}" "Repairing Lynis functions ownership"
assert_contains "${DNF_ARGS_FILE}" "--installroot ${ALT_ROOT}"
assert_contains "${DNF_ARGS_FILE}" "clamav-update"
assert_contains "${CHOWN_ARGS_FILE}" "0:0 ${ALT_ROOT}/usr/share/lynis/include/functions"
