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
OUTPUT_DIR="${TMP_DIR}/output"

mkdir -p "${MOCK_BIN}"

cat >"${MOCK_BIN}/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "+%Y%m%d-%H%M%S" ]; then
  printf '20260103-030405\n'
elif [ "${1:-}" = "--iso-8601=seconds" ]; then
  printf '2026-01-03T03:04:05+00:00\n'
else
  /usr/bin/date "$@"
fi
EOF

cat >"${MOCK_BIN}/rpm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-q" ]; then
  case "${2:-}" in
    clamav|clamav-update|audit|openscap-scanner)
      printf '%s-1.0-1.fc43\n' "${2}"
      exit 0
      ;;
    *)
      exit 1
      ;;
  esac
fi
exit 1
EOF

cat >"${MOCK_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-}"
unit="${2:-}"
case "${mode}:${unit}" in
  is-enabled:auditd.service)
    printf 'enabled\n'
    exit 0
    ;;
  is-active:auditd.service)
    printf 'active\n'
    exit 0
    ;;
  is-enabled:clamd.service)
    printf 'disabled\n'
    exit 1
    ;;
  is-active:clamd.service)
    printf 'inactive\n'
    exit 3
    ;;
  is-enabled:freshclam.service)
    printf 'enabled\n'
    exit 0
    ;;
  is-active:freshclam.service)
    printf 'active\n'
    exit 0
    ;;
  is-enabled:falco.service)
    printf 'not-found\n'
    exit 4
    ;;
  is-active:falco.service)
    printf 'not-found\n'
    exit 4
    ;;
  *)
    exit 1
    ;;
esac
EOF

for tool_name in clamscan freshclam auditctl ausearch oscap; do
  cat >"${MOCK_BIN}/${tool_name}" <<EOF
#!/usr/bin/env bash
exit 0
EOF
done

chmod +x "${MOCK_BIN}"/*

export PATH="${MOCK_BIN}:${PATH}"

REPORT_DIR="$("${ROOT_DIR}/scripts/analyze_security_posture.sh" --output-dir "${OUTPUT_DIR}" --path-only)"

assert_file_exists "${REPORT_DIR}/security-summary.md"
assert_file_exists "${REPORT_DIR}/tables/security-tools.tsv"
assert_file_exists "${REPORT_DIR}/commands/command-paths.txt"
assert_file_exists "${REPORT_DIR}/commands/package-checks.txt"
assert_file_exists "${REPORT_DIR}/commands/service-checks.txt"

assert_contains "${REPORT_DIR}/security-summary.md" "- Tool rows analyzed: 10"
assert_contains "${REPORT_DIR}/security-summary.md" "- Fully present rows: 4"
assert_contains "${REPORT_DIR}/security-summary.md" "- Partial rows: 1"
assert_contains "${REPORT_DIR}/security-summary.md" "- Coverage gaps: 5"
assert_contains "${REPORT_DIR}/security-summary.md" "- Config source: \`security-tools.tsv\`"
assert_contains "${REPORT_DIR}/security-summary.md" "- Malware coverage gap: no"
assert_contains "${REPORT_DIR}/security-summary.md" "- Rootkit coverage gap: yes"
assert_contains "${REPORT_DIR}/tables/security-tools.tsv" $'malware\tClamAV scanner\tclamscan\tpresent'
assert_contains "${REPORT_DIR}/tables/security-tools.tsv" $'audit\tauditctl\tauditctl\tpresent'
assert_contains "${REPORT_DIR}/tables/security-tools.tsv" $'baseline\tOpenSCAP\toscap\tpresent'
assert_contains "${REPORT_DIR}/tables/security-tools.tsv" $'openscap-scanner,scap-security-guide\tpartial\t-\t-\t-\tyes\tpartial'
assert_contains "${REPORT_DIR}/tables/security-tools.tsv" $'runtime\tFalco\tfalco\tmissing'
assert_contains "${REPORT_DIR}/commands/service-checks.txt" $'auditctl\tauditd.service\tenabled\tactive'
assert_contains "${REPORT_DIR}/commands/service-checks.txt" $'ClamAV updater\tfreshclam.service\tenabled\tactive'
