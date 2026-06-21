#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

MOCK_BIN="${TMP_DIR}/mock-bin"
OUTPUT_DIR="${TMP_DIR}/output"
mkdir -p "${MOCK_BIN}"

cat >"${MOCK_BIN}/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "+%Y%m%d-%H%M%S" ]; then
  printf '20260107-070809\n'
elif [ "${1:-}" = "--iso-8601=seconds" ]; then
  printf '2026-01-07T07:08:09+00:00\n'
else
  /usr/bin/date "$@"
fi
EOF

cat >"${MOCK_BIN}/auditctl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-s" ]; then
  printf 'enabled 1\n'
else
  printf -- '-w /etc/passwd -p wa\n'
fi
EOF

cat >"${MOCK_BIN}/ausearch" <<'EOF'
#!/usr/bin/env bash
printf 'type=USER_LOGIN msg=audit(1.1:1): user login\n'
EOF

cat >"${MOCK_BIN}/aureport" <<'EOF'
#!/usr/bin/env bash
printf 'Authentication Report Summary\n'
EOF

cat >"${MOCK_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  is-enabled:auditd.service) printf 'enabled\n'; exit 0 ;;
  is-active:auditd.service) printf 'active\n'; exit 0 ;;
  *) exit 1 ;;
esac
EOF

chmod +x "${MOCK_BIN}"/*
export PATH="${MOCK_BIN}:${PATH}"

REPORT_DIR="$("${ROOT_DIR}/scripts/scan_security_audit.sh" --output-dir "${OUTPUT_DIR}" --start yesterday --path-only)"

assert_file_exists "${REPORT_DIR}/scan-summary.md"
assert_file_exists "${REPORT_DIR}/commands/auditctl-status.txt"
assert_file_exists "${REPORT_DIR}/commands/ausearch-auth.txt"
assert_file_exists "${REPORT_DIR}/commands/aureport-auth.txt"
assert_contains "${REPORT_DIR}/scan-summary.md" "- auditctl present: yes"
assert_contains "${REPORT_DIR}/scan-summary.md" "- auditd.service active: active"
assert_contains "${REPORT_DIR}/scan-summary.md" "- Event window start: yesterday"
