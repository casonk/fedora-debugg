#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ROOT_PREFIX=""
DRY_RUN=0
SKIP_FRESHCLAM=0
SKIP_AIDE_INIT=0
DATastream_PATH="/usr/share/xml/scap/ssg/content/ssg-fedora-ds.xml"

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/init_security_tooling.sh [options]

Initialize the conservative Fedora security tool stack after packages are
installed. This refreshes ClamAV signatures, initializes the AIDE database, and
verifies OpenSCAP content presence.

Options:
  --root <path>         Initialize an alternate root and skip the root-user gate.
  --dry-run             Print the actions without executing them.
  --skip-freshclam      Skip the ClamAV signature refresh.
  --skip-aide-init      Skip AIDE database initialization.
  --oscap-datastream <path>
                        Override the OpenSCAP datastream path to verify.
  --help                Show this help text.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -lt 2 ] && { echo "Missing value for --root" >&2; exit 1; }
      ROOT_PREFIX="${2%/}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --skip-freshclam)
      SKIP_FRESHCLAM=1
      shift
      ;;
    --skip-aide-init)
      SKIP_AIDE_INIT=1
      shift
      ;;
    --oscap-datastream)
      [ $# -lt 2 ] && { echo "Missing value for --oscap-datastream" >&2; exit 1; }
      DATastream_PATH="$2"
      shift 2
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

if [ -z "${ROOT_PREFIX}" ] && [ "${EUID}" -ne 0 ]; then
  echo "Run this initializer with sudo so it can refresh signatures and write the AIDE database." >&2
  echo "Suggested command:" >&2
  echo "  sudo ./scripts/init_security_tooling.sh" >&2
  exit 1
fi

run_cmd() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    printf 'DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

rooted_path() {
  local path="$1"
  if [ -n "${ROOT_PREFIX}" ]; then
    printf '%s\n' "${ROOT_PREFIX}${path}"
  else
    printf '%s\n' "${path}"
  fi
}

datastream_rooted_path() {
  if [ -n "${ROOT_PREFIX}" ] && [[ "${DATastream_PATH}" = /* ]]; then
    printf '%s\n' "${ROOT_PREFIX}${DATastream_PATH}"
  else
    printf '%s\n' "${DATastream_PATH}"
  fi
}

activate_aide_database() {
  local new_db gz_new_db active_db gz_active_db

  new_db="$(rooted_path /var/lib/aide/aide.db.new)"
  gz_new_db="$(rooted_path /var/lib/aide/aide.db.new.gz)"
  active_db="$(rooted_path /var/lib/aide/aide.db)"
  gz_active_db="$(rooted_path /var/lib/aide/aide.db.gz)"

  if [ -f "${gz_new_db}" ] && [ ! -f "${gz_active_db}" ]; then
    run_cmd mv "${gz_new_db}" "${gz_active_db}"
    echo "Activated AIDE database: ${gz_active_db}"
    return 0
  fi

  if [ -f "${new_db}" ] && [ ! -f "${active_db}" ]; then
    run_cmd mv "${new_db}" "${active_db}"
    echo "Activated AIDE database: ${active_db}"
    return 0
  fi

  if [ -f "${gz_active_db}" ] || [ -f "${active_db}" ]; then
    echo "AIDE database already active."
    return 0
  fi

  echo "AIDE initialization did not produce an activatable database." >&2
  return 1
}

main() {
  local datastream_rooted
  local freshclam_conf
  local aide_conf

  freshclam_conf="$(rooted_path /etc/freshclam.conf)"
  aide_conf="$(rooted_path /etc/aide.conf)"
  datastream_rooted="$(datastream_rooted_path)"

  if [ "${SKIP_FRESHCLAM}" -eq 0 ]; then
    if [ ! -r "${freshclam_conf}" ]; then
      echo "Missing or unreadable freshclam config: ${freshclam_conf}" >&2
      exit 1
    fi
    echo "Refreshing ClamAV signatures"
    run_cmd freshclam
  else
    echo "Skipping freshclam refresh."
  fi

  if [ "${SKIP_AIDE_INIT}" -eq 0 ]; then
    if [ ! -r "${aide_conf}" ]; then
      echo "Missing or unreadable AIDE config: ${aide_conf}" >&2
      exit 1
    fi
    echo "Initializing AIDE database"
    run_cmd aide --init
    activate_aide_database
  else
    echo "Skipping AIDE initialization."
  fi

  if [ -f "${datastream_rooted}" ]; then
    echo "OpenSCAP datastream present: ${datastream_rooted}"
  else
    echo "OpenSCAP datastream missing: ${datastream_rooted}" >&2
    exit 1
  fi

  if [ -n "${ROOT_PREFIX}" ]; then
    echo "Security tooling initialization completed for alternate root: ${ROOT_PREFIX}"
  else
    echo "Security tooling initialization completed."
    echo "Next step: run the Phase 3 security wrapper scripts."
  fi
}

main
