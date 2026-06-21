#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT_BASE="${ROOT_DIR}/artifacts"
REPORT_DIR=""
PATH_ONLY=0
RUN_LYNIS=0
RUN_AIDE_CHECK=0
OSCAP_DATASTREAM=""

usage() {
  cat <<'EOF'
Usage: ./scripts/scan_security_baseline.sh [options]

Capture baseline/integrity readiness details for Lynis, AIDE, and OpenSCAP, and
optionally run selected checks when the host is already provisioned.

Options:
  --output-dir <dir>      Output base directory (default: ./artifacts).
  --report-dir <dir>      Write the report directly to this directory.
  --run-lynis            Run `lynis audit system --quick --no-colors`.
  --run-aide-check       Run `aide --check`.
  --oscap-datastream <path>
                         Run `oscap info` against this datastream path.
  --path-only            Print only the generated report path.
  --help                 Show this help text.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --output-dir)
      [ $# -lt 2 ] && { echo "Missing value for --output-dir" >&2; exit 1; }
      OUTPUT_BASE="$2"
      shift 2
      ;;
    --report-dir)
      [ $# -lt 2 ] && { echo "Missing value for --report-dir" >&2; exit 1; }
      REPORT_DIR="$2"
      shift 2
      ;;
    --run-lynis)
      RUN_LYNIS=1
      shift
      ;;
    --run-aide-check)
      RUN_AIDE_CHECK=1
      shift
      ;;
    --oscap-datastream)
      [ $# -lt 2 ] && { echo "Missing value for --oscap-datastream" >&2; exit 1; }
      OSCAP_DATASTREAM="$2"
      shift 2
      ;;
    --path-only)
      PATH_ONLY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "${OUTPUT_BASE}" in
  /*) ;;
  *) OUTPUT_BASE="${ROOT_DIR}/${OUTPUT_BASE}" ;;
esac
case "${REPORT_DIR}" in
  "") ;;
  /*) ;;
  *) REPORT_DIR="${ROOT_DIR}/${REPORT_DIR}" ;;
esac
case "${OSCAP_DATASTREAM}" in
  "") ;;
  /*) ;;
  *) OSCAP_DATASTREAM="${ROOT_DIR}/${OSCAP_DATASTREAM}" ;;
esac

if [ -z "${REPORT_DIR}" ]; then
  REPORT_DIR="${OUTPUT_BASE}/security-baseline-$(date +%Y%m%d-%H%M%S)"
fi

COMMANDS_DIR="${REPORT_DIR}/commands"
SUMMARY_FILE="${REPORT_DIR}/scan-summary.md"
mkdir -p "${COMMANDS_DIR}"

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

write_cmd_output() {
  local file_name="$1"
  shift
  local out_file="${COMMANDS_DIR}/${file_name}"
  local err_file="${out_file}.stderr"
  local cmd=("$@")
  local status

  : >"${out_file}"
  rm -f "${err_file}"

  if ! has_cmd "${cmd[0]}"; then
    printf 'MISSING: %s\n' "${cmd[0]}" >"${out_file}"
    return 0
  fi

  "${cmd[@]}" >"${out_file}" 2>"${err_file}"
  status=$?
  printf '# Exit status: %s\n' "${status}" >>"${out_file}"
  if [ ! -s "${err_file}" ]; then
    rm -f "${err_file}"
  fi
  return 0
}

find_aide_db() {
  local candidate
  for candidate in /var/lib/aide/aide.db.gz /var/lib/aide/aide.db /var/lib/aide/aide.db.new.gz; do
    if [ -f "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  printf 'not found\n'
}

write_cmd_output "lynis-version.txt" lynis show version
write_cmd_output "aide-version.txt" aide --version
write_cmd_output "oscap-version.txt" oscap --version
printf '%s\n' "$(find_aide_db)" >"${COMMANDS_DIR}/aide-database-path.txt"

if [ "${RUN_LYNIS}" -eq 1 ]; then
  write_cmd_output "lynis-audit.txt" lynis audit system --quick --no-colors
fi

if [ "${RUN_AIDE_CHECK}" -eq 1 ]; then
  write_cmd_output "aide-check.txt" aide --check
fi

if [ -n "${OSCAP_DATASTREAM}" ]; then
  write_cmd_output "oscap-info.txt" oscap info "${OSCAP_DATASTREAM}"
fi

cat >"${SUMMARY_FILE}" <<EOF
# Baseline Security Scan Summary

Generated: $(date --iso-8601=seconds)

- Lynis present: $(has_cmd lynis && printf 'yes' || printf 'no')
- AIDE present: $(has_cmd aide && printf 'yes' || printf 'no')
- OpenSCAP present: $(has_cmd oscap && printf 'yes' || printf 'no')
- AIDE database path: $(cat "${COMMANDS_DIR}/aide-database-path.txt")
- Lynis audit executed: $( [ "${RUN_LYNIS}" -eq 1 ] && printf 'yes' || printf 'no' )
- AIDE check executed: $( [ "${RUN_AIDE_CHECK}" -eq 1 ] && printf 'yes' || printf 'no' )
- OpenSCAP content inspected: $( [ -n "${OSCAP_DATASTREAM}" ] && printf '%s' "${OSCAP_DATASTREAM}" || printf '<none>' )
EOF

if [ "${PATH_ONLY}" -eq 1 ]; then
  printf '%s\n' "${REPORT_DIR}"
else
  echo "Baseline security scan: ${SUMMARY_FILE}"
fi
