#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_CONFIG_PATH="${ROOT_DIR}/config/security/security-tools.tsv"

OUTPUT_BASE="${ROOT_DIR}/artifacts"
PATH_ONLY=0
REPORT_DIR=""
CONFIG_PATH="${DEFAULT_CONFIG_PATH}"

usage() {
  cat <<'EOF'
Usage: ./scripts/analyze_security_posture.sh [options]

Inventory local security tooling and host detection posture without making host
changes or asserting that the system is clean.

Phase 1 scope:
  - Detect whether common malware, rootkit, audit, integrity, and baseline
    assessment tools are installed.
  - Capture lightweight service status where a system service is expected.
  - Summarize obvious coverage gaps so later phases can add deeper scans.

Options:
  --output-dir <dir>      Output base directory (default: ./artifacts).
  --report-dir <dir>      Write the report directly to this directory.
  --config <path>         Security tool matrix TSV (default: config/security/security-tools.tsv).
  --path-only             Print only the generated report path.
  --help                  Show this help message.
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
    --config)
      [ $# -lt 2 ] && { echo "Missing value for --config" >&2; exit 1; }
      CONFIG_PATH="$2"
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
  "")
    ;;
  /*)
    ;;
  *)
    REPORT_DIR="${ROOT_DIR}/${REPORT_DIR}"
    ;;
esac

case "${CONFIG_PATH}" in
  /*) ;;
  *) CONFIG_PATH="${ROOT_DIR}/${CONFIG_PATH}" ;;
esac

[ -f "${CONFIG_PATH}" ] || {
  echo "Missing config file: ${CONFIG_PATH}" >&2
  exit 1
}

if [ -z "${REPORT_DIR}" ]; then
  TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
  REPORT_DIR="${OUTPUT_BASE}/security-audit-${TIMESTAMP}"
fi
COMMANDS_DIR="${REPORT_DIR}/commands"
TABLES_DIR="${REPORT_DIR}/tables"
SUMMARY_FILE="${REPORT_DIR}/security-summary.md"
TOOLS_TABLE="${TABLES_DIR}/security-tools.tsv"
PACKAGE_CHECKS_FILE="${COMMANDS_DIR}/package-checks.txt"
SERVICE_CHECKS_FILE="${COMMANDS_DIR}/service-checks.txt"
COMMAND_PATHS_FILE="${COMMANDS_DIR}/command-paths.txt"

mkdir -p "${COMMANDS_DIR}" "${TABLES_DIR}"

log() {
  if [ "${PATH_ONLY}" -eq 0 ]; then
    printf '[security] %s\n' "$*"
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sanitize_field() {
  local value="${1:-}"
  value="${value//$'\t'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  printf '%s' "${value}"
}

command_status() {
  if has_cmd "$1"; then
    printf 'present'
  else
    printf 'missing'
  fi
}

command_path() {
  if has_cmd "$1"; then
    command -v "$1"
  else
    printf '-'
  fi
}

package_status() {
  local pkg_csv="$1"
  local pkg
  local installed=0
  local total=0

  if [ -z "${pkg_csv}" ] || [ "${pkg_csv}" = "-" ]; then
    printf '-'
    return 0
  fi

  if ! has_cmd rpm; then
    printf 'unknown'
    return 0
  fi

  IFS=',' read -r -a pkgs <<<"${pkg_csv}"
  for pkg in "${pkgs[@]}"; do
    [ -n "${pkg}" ] || continue
    total=$((total + 1))
    if rpm -q "${pkg}" >/dev/null 2>&1; then
      installed=$((installed + 1))
    fi
  done

  if [ "${total}" -eq 0 ]; then
    printf '-'
  elif [ "${installed}" -eq "${total}" ]; then
    printf 'installed'
  elif [ "${installed}" -eq 0 ]; then
    printf 'missing'
  else
    printf 'partial'
  fi
}

service_state() {
  local unit="$1"
  local mode="$2"
  local output
  local rc

  if [ -z "${unit}" ] || [ "${unit}" = "-" ]; then
    printf '-'
    return 0
  fi

  if ! has_cmd systemctl; then
    printf 'unknown'
    return 0
  fi

  output="$(systemctl "${mode}" "${unit}" 2>/dev/null)"
  rc=$?
  output="${output%%$'\n'*}"

  case "${rc}" in
    0)
      printf '%s' "${output:-ok}"
      ;;
    *)
      case "${output}" in
        *"not-found"*|*"No such file"*|*"not loaded"*)
          printf 'not-found'
          ;;
        "")
          if [ "${mode}" = "is-enabled" ]; then
            printf 'disabled'
          else
            printf 'inactive'
          fi
          ;;
        *)
          printf '%s' "$(sanitize_field "${output}")"
          ;;
      esac
      ;;
  esac
}

phase1_assessment() {
  local cmd_state="$1"
  local pkg_state="$2"

  if [ "${cmd_state}" = "present" ] && { [ "${pkg_state}" = "installed" ] || [ "${pkg_state}" = "-" ] || [ "${pkg_state}" = "unknown" ]; }; then
    printf 'present'
  elif [ "${cmd_state}" = "present" ] || [ "${pkg_state}" = "partial" ]; then
    printf 'partial'
  else
    printf 'gap'
  fi
}

log "Writing security posture inventory under ${REPORT_DIR}"

{
  printf '# Command paths\n'
  printf '# tool\tcommand\tstatus\tpath\n'
} >"${COMMAND_PATHS_FILE}"

{
  printf '# Package checks\n'
  printf '# tool\tpackages\tstatus\n'
} >"${PACKAGE_CHECKS_FILE}"

{
  printf '# Service checks\n'
  printf '# tool\tservice\tenabled\tactive\n'
} >"${SERVICE_CHECKS_FILE}"

printf 'category\ttool\tcommand\tcommand_status\tcommand_path\tpackages\tpackage_status\tservice\tservice_enabled\tservice_active\tplanned_deep_scan\tphase1_assessment\n' >"${TOOLS_TABLE}"

present_count=0
partial_count=0
gap_count=0
malware_gap=0
rootkit_gap=0
integrity_gap=0
audit_runtime_gap=0
baseline_gap=0

while IFS=$'\t' read -r category tool_name command_name package_names service_name planned_deep_scan; do
  [ -n "${category}" ] || continue
  cmd_state="$(command_status "${command_name}")"
  cmd_path="$(command_path "${command_name}")"
  pkg_state="$(package_status "${package_names}")"
  service_enabled="$(service_state "${service_name}" "is-enabled")"
  service_active="$(service_state "${service_name}" "is-active")"
  assessment="$(phase1_assessment "${cmd_state}" "${pkg_state}")"

  case "${assessment}" in
    present) present_count=$((present_count + 1)) ;;
    partial) partial_count=$((partial_count + 1)) ;;
    *) gap_count=$((gap_count + 1)) ;;
  esac

  if [ "${assessment}" = "gap" ]; then
    case "${category}" in
      malware)
        malware_gap=1
        ;;
      rootkit)
        rootkit_gap=1
        ;;
      integrity)
        integrity_gap=1
        ;;
      audit|runtime)
        audit_runtime_gap=1
        ;;
      baseline)
        baseline_gap=1
        ;;
    esac
  fi

  printf '%s\t%s\t%s\t%s\n' \
    "${tool_name}" \
    "${command_name}" \
    "${cmd_state}" \
    "$(sanitize_field "${cmd_path}")" >>"${COMMAND_PATHS_FILE}"

  printf '%s\t%s\t%s\n' \
    "${tool_name}" \
    "${package_names}" \
    "${pkg_state}" >>"${PACKAGE_CHECKS_FILE}"

  printf '%s\t%s\t%s\t%s\n' \
    "${tool_name}" \
    "${service_name}" \
    "${service_enabled}" \
    "${service_active}" >>"${SERVICE_CHECKS_FILE}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${category}" \
    "${tool_name}" \
    "${command_name}" \
    "${cmd_state}" \
    "$(sanitize_field "${cmd_path}")" \
    "${package_names}" \
    "${pkg_state}" \
    "${service_name}" \
    "${service_enabled}" \
    "${service_active}" \
    "${planned_deep_scan:-no}" \
    "${assessment}" >>"${TOOLS_TABLE}"
done < <(tail -n +2 "${CONFIG_PATH}")

tool_row_count=$((present_count + partial_count + gap_count))

cat >"${SUMMARY_FILE}" <<EOF
# Security Posture Summary

Generated: $(date --iso-8601=seconds)

This Phase 1 report inventories local security tooling presence and lightweight
service posture only. It does not perform a deep malware scan, file-integrity
verification, or intrusion investigation, and it should not be treated as proof
that the host is clean.

## Coverage Snapshot

- Tool rows analyzed: ${tool_row_count}
- Fully present rows: ${present_count}
- Partial rows: ${partial_count}
- Coverage gaps: ${gap_count}

## Current Scope

- Malware tooling: ClamAV scanner/updater presence only
- Rootkit tooling: inventory only
- File integrity tooling: inventory only
- Audit/runtime detection tooling: inventory and service state only
- Baseline/compliance tooling: inventory only

## Outputs

- Config source: \`$(basename "${CONFIG_PATH}")\`
- Tool table: \`tables/security-tools.tsv\`
- Command paths: \`commands/command-paths.txt\`
- Package checks: \`commands/package-checks.txt\`
- Service checks: \`commands/service-checks.txt\`

## Phase 2 Candidates

- Add optional summary integration into \`scripts/run_workflow.sh\` and
  \`artifacts/latest/analysis-summary.md\`.
- Export compact security coverage signals for \`tachometer\`.
- Add host-backed scan wrappers only when the required packages and update paths
  are explicitly provisioned on this machine.

## Category Gap Flags

- Malware coverage gap: $( [ "${malware_gap}" -eq 1 ] && printf 'yes' || printf 'no' )
- Rootkit coverage gap: $( [ "${rootkit_gap}" -eq 1 ] && printf 'yes' || printf 'no' )
- Integrity coverage gap: $( [ "${integrity_gap}" -eq 1 ] && printf 'yes' || printf 'no' )
- Audit/runtime coverage gap: $( [ "${audit_runtime_gap}" -eq 1 ] && printf 'yes' || printf 'no' )
- Baseline coverage gap: $( [ "${baseline_gap}" -eq 1 ] && printf 'yes' || printf 'no' )
EOF

if [ "${PATH_ONLY}" -eq 1 ]; then
  printf '%s\n' "${REPORT_DIR}"
else
  echo "Security summary: ${SUMMARY_FILE}"
fi
