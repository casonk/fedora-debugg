#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

MOCK_BIN="${TMP_DIR}/mock-bin"
SCAN_TARGET="${TMP_DIR}/target"
OUTPUT_DIR="${TMP_DIR}/output"
mkdir -p "${MOCK_BIN}" "${SCAN_TARGET}"

cat >"${MOCK_BIN}/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "+%Y%m%d-%H%M%S" ]; then
  printf '20260105-050607\n'
elif [ "${1:-}" = "--iso-8601=seconds" ]; then
  printf '2026-01-05T05:06:07+00:00\n'
else
  /usr/bin/date "$@"
fi
EOF

cat >"${MOCK_BIN}/clamscan" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  printf 'ClamAV 1.4.2\n'
  exit 0
fi
printf '----------- SCAN SUMMARY -----------\n'
printf 'Infected files: 2\n'
EOF

cat >"${MOCK_BIN}/freshclam" <<'EOF'
#!/usr/bin/env bash
printf 'ClamAV update process 1.0\n'
EOF

cat >"${MOCK_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  is-enabled:clamd.service) printf 'enabled\n'; exit 0 ;;
  is-active:clamd.service) printf 'active\n'; exit 0 ;;
  is-enabled:freshclam.service) printf 'disabled\n'; exit 1 ;;
  is-active:freshclam.service) printf 'inactive\n'; exit 3 ;;
  *) exit 1 ;;
esac
EOF

chmod +x "${MOCK_BIN}"/*
export PATH="${MOCK_BIN}:${PATH}"

REPORT_DIR="$("${ROOT_DIR}/scripts/scan_security_clamav.sh" --output-dir "${OUTPUT_DIR}" --scan-target "${SCAN_TARGET}" --path-only)"

assert_file_exists "${REPORT_DIR}/scan-summary.md"
assert_file_exists "${REPORT_DIR}/commands/clamscan-target.txt"
assert_contains "${REPORT_DIR}/scan-summary.md" "- ClamAV scanner present: yes"
assert_contains "${REPORT_DIR}/scan-summary.md" "- Scan executed: yes"
assert_contains "${REPORT_DIR}/scan-summary.md" "- Infected files reported: 2"
assert_contains "${REPORT_DIR}/commands/clamd-is-enabled.txt" "enabled"
