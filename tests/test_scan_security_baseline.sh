#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

MOCK_BIN="${TMP_DIR}/mock-bin"
OUTPUT_DIR="${TMP_DIR}/output"
DATASTREAM="${TMP_DIR}/ssg-fedora-ds.xml"
mkdir -p "${MOCK_BIN}"
printf '<xml />\n' >"${DATASTREAM}"

cat >"${MOCK_BIN}/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "+%Y%m%d-%H%M%S" ]; then
  printf '20260106-060708\n'
elif [ "${1:-}" = "--iso-8601=seconds" ]; then
  printf '2026-01-06T06:07:08+00:00\n'
else
  /usr/bin/date "$@"
fi
EOF

cat >"${MOCK_BIN}/lynis" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "show" ]; then
  printf '3.1.2\n'
else
  printf 'lynis audit ok\n'
fi
EOF

cat >"${MOCK_BIN}/aide" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'AIDE 0.18\n'
else
  printf 'AIDE found NO differences\n'
fi
EOF

cat >"${MOCK_BIN}/oscap" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'OpenSCAP 1.4.0\n'
else
  printf 'Document type: XCCDF Checklist\n'
fi
EOF

chmod +x "${MOCK_BIN}"/*
export PATH="${MOCK_BIN}:${PATH}"

REPORT_DIR="$("${ROOT_DIR}/scripts/scan_security_baseline.sh" --output-dir "${OUTPUT_DIR}" --run-lynis --run-aide-check --oscap-datastream "${DATASTREAM}" --path-only)"

assert_file_exists "${REPORT_DIR}/scan-summary.md"
assert_file_exists "${REPORT_DIR}/commands/lynis-audit.txt"
assert_file_exists "${REPORT_DIR}/commands/aide-check.txt"
assert_file_exists "${REPORT_DIR}/commands/oscap-info.txt"
assert_contains "${REPORT_DIR}/scan-summary.md" "- Lynis present: yes"
assert_contains "${REPORT_DIR}/scan-summary.md" "- AIDE check executed: yes"
assert_contains "${REPORT_DIR}/scan-summary.md" "- OpenSCAP content inspected: ${DATASTREAM}"
