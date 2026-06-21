#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT_BASE="${ROOT_DIR}/artifacts"
REPORT_DIR=""
PATH_ONLY=0
SCAN_TARGET=""

usage() {
  cat <<'EOF'
Usage: ./scripts/scan_security_clamav.sh [options]

Capture ClamAV readiness details and optionally run a recursive scan against an
explicit target path.

Options:
  --output-dir <dir>      Output base directory (default: ./artifacts).
  --report-dir <dir>      Write the report directly to this directory.
  --scan-target <path>    Run `clamscan -r --infected` against this path.
  --path-only             Print only the generated report path.
  --help                  Show this help text.
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
    --scan-target)
      [ $# -lt 2 ] && { echo "Missing value for --scan-target" >&2; exit 1; }
      SCAN_TARGET="$2"
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
case "${SCAN_TARGET}" in
  "") ;;
  /*) ;;
  *) SCAN_TARGET="${ROOT_DIR}/${SCAN_TARGET}" ;;
esac

if [ -z "${REPORT_DIR}" ]; then
  REPORT_DIR="${OUTPUT_BASE}/security-clamav-$(date +%Y%m%d-%H%M%S)"
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

service_state() {
  local unit="$1"
  local mode="$2"

  if ! has_cmd systemctl; then
    printf 'unknown'
    return 0
  fi

  if output="$(systemctl "${mode}" "${unit}" 2>/dev/null)"; then
    printf '%s' "${output%%$'\n'*}"
  else
    output="${output%%$'\n'*}"
    printf '%s' "${output:-unknown}"
  fi
}

infected_count() {
  local file="${COMMANDS_DIR}/clamscan-target.txt"
  [ -f "${file}" ] || { printf '0'; return 0; }
  awk -F ': ' '/^Infected files:/ {print $2; exit}' "${file}" 2>/dev/null || printf '0'
}

write_cmd_output "clamscan-version.txt" clamscan --version
write_cmd_output "freshclam-version.txt" freshclam --version
printf '%s\n' "$(service_state clamd.service is-enabled)" >"${COMMANDS_DIR}/clamd-is-enabled.txt"
printf '%s\n' "$(service_state clamd.service is-active)" >"${COMMANDS_DIR}/clamd-is-active.txt"
printf '%s\n' "$(service_state freshclam.service is-enabled)" >"${COMMANDS_DIR}/freshclam-is-enabled.txt"
printf '%s\n' "$(service_state freshclam.service is-active)" >"${COMMANDS_DIR}/freshclam-is-active.txt"

scan_executed="no"
scan_target_label="${SCAN_TARGET:-<none>}"
if [ -n "${SCAN_TARGET}" ]; then
  write_cmd_output "clamscan-target.txt" clamscan -r --infected "${SCAN_TARGET}"
  scan_executed="yes"
fi

cat >"${SUMMARY_FILE}" <<EOF
# ClamAV Security Scan Summary

Generated: $(date --iso-8601=seconds)

- ClamAV scanner present: $(has_cmd clamscan && printf 'yes' || printf 'no')
- ClamAV updater present: $(has_cmd freshclam && printf 'yes' || printf 'no')
- clamd.service enabled: $(cat "${COMMANDS_DIR}/clamd-is-enabled.txt")
- clamd.service active: $(cat "${COMMANDS_DIR}/clamd-is-active.txt")
- freshclam.service enabled: $(cat "${COMMANDS_DIR}/freshclam-is-enabled.txt")
- freshclam.service active: $(cat "${COMMANDS_DIR}/freshclam-is-active.txt")
- Scan executed: ${scan_executed}
- Scan target: ${scan_target_label}
EOF

if [ "${scan_executed}" = "yes" ]; then
  {
    echo "- Infected files reported: $(infected_count)"
    echo
    echo "Actual recursive scanning is only performed when --scan-target is set."
  } >>"${SUMMARY_FILE}"
else
  {
    echo
    echo "No filesystem scan was run. Provide --scan-target to run ClamAV against"
    echo "an explicit path."
  } >>"${SUMMARY_FILE}"
fi

if [ "${PATH_ONLY}" -eq 1 ]; then
  printf '%s\n' "${REPORT_DIR}"
else
  echo "ClamAV security scan: ${SUMMARY_FILE}"
fi
