#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT_BASE="${ROOT_DIR}/artifacts"
REPORT_DIR=""
PATH_ONLY=0
AUDIT_START="${AUDIT_START:-today}"

usage() {
  cat <<'EOF'
Usage: ./scripts/scan_security_audit.sh [options]

Capture auditd readiness and recent evidence using auditctl/ausearch/aureport
when those tools are already installed on the host.

Options:
  --output-dir <dir>      Output base directory (default: ./artifacts).
  --report-dir <dir>      Write the report directly to this directory.
  --start <when>          ausearch/aureport start window (default: today).
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
    --start)
      [ $# -lt 2 ] && { echo "Missing value for --start" >&2; exit 1; }
      AUDIT_START="$2"
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

if [ -z "${REPORT_DIR}" ]; then
  REPORT_DIR="${OUTPUT_BASE}/security-auditd-$(date +%Y%m%d-%H%M%S)"
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

write_cmd_output "auditctl-status.txt" auditctl -s
write_cmd_output "auditctl-rules.txt" auditctl -l
write_cmd_output "ausearch-auth.txt" ausearch --start "${AUDIT_START}" -m USER_AUTH,USER_LOGIN
write_cmd_output "ausearch-avc.txt" ausearch --start "${AUDIT_START}" -m AVC
write_cmd_output "aureport-auth.txt" aureport --auth --summary -ts "${AUDIT_START}"
printf '%s\n' "$(service_state auditd.service is-enabled)" >"${COMMANDS_DIR}/auditd-is-enabled.txt"
printf '%s\n' "$(service_state auditd.service is-active)" >"${COMMANDS_DIR}/auditd-is-active.txt"

cat >"${SUMMARY_FILE}" <<EOF
# auditd Security Scan Summary

Generated: $(date --iso-8601=seconds)

- auditctl present: $(has_cmd auditctl && printf 'yes' || printf 'no')
- ausearch present: $(has_cmd ausearch && printf 'yes' || printf 'no')
- aureport present: $(has_cmd aureport && printf 'yes' || printf 'no')
- auditd.service enabled: $(cat "${COMMANDS_DIR}/auditd-is-enabled.txt")
- auditd.service active: $(cat "${COMMANDS_DIR}/auditd-is-active.txt")
- Event window start: ${AUDIT_START}
EOF

if [ "${PATH_ONLY}" -eq 1 ]; then
  printf '%s\n' "${REPORT_DIR}"
else
  echo "auditd security scan: ${SUMMARY_FILE}"
fi
