#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ROOT_PREFIX=""
SETTINGS_NAME="99-fedora-debugg-disable-auto-suspend"

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/install_gdm_no_auto_suspend.sh [--root <path>]

Install a GDM-only dconf policy that disables automatic suspend at the login
screen. Intentional suspend remains available after login.

Options:
  --root <path>  Install into an alternate root and skip dconf update.
  --help         Show this help message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      if [ $# -lt 2 ]; then
        echo "Missing value for --root" >&2
        exit 1
      fi
      ROOT_PREFIX="${2%/}"
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
  echo "Run this installer with sudo so it can write the GDM system dconf database." >&2
  exit 1
fi

install_config() {
  local source_file="$1"
  local target_file="$2"

  if [ -e "${target_file}" ]; then
    if cmp -s "${source_file}" "${target_file}"; then
      echo "Already installed: ${target_file}"
      return 0
    fi

    echo "Refusing to overwrite an existing different file: ${target_file}" >&2
    return 1
  fi

  install -D -m 0644 "${source_file}" "${target_file}"
  echo "Installed: ${target_file}"
}

install_config \
  "${ROOT_DIR}/config/gdm.d/${SETTINGS_NAME}" \
  "${ROOT_PREFIX}/etc/dconf/db/gdm.d/${SETTINGS_NAME}" || exit 1
install_config \
  "${ROOT_DIR}/config/gdm.d/locks/${SETTINGS_NAME}" \
  "${ROOT_PREFIX}/etc/dconf/db/gdm.d/locks/${SETTINGS_NAME}" || exit 1

if [ -n "${ROOT_PREFIX}" ]; then
  echo "Skipped dconf update for alternate root: ${ROOT_PREFIX}"
elif command -v dconf >/dev/null 2>&1; then
  dconf update
  echo "Updated the system dconf databases."
else
  echo "The files were installed, but dconf is missing; run 'sudo dconf update' after installing it." >&2
  exit 1
fi

echo "GDM automatic suspend is disabled. The policy takes effect on the next GDM login-screen start."
