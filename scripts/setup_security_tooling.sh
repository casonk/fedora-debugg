#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ROOT_PREFIX=""
DRY_RUN=0
PACKAGES=(
  clamav
  clamav-update
  aide
  lynis
  openscap-scanner
  scap-security-guide
  audit
)

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/setup_security_tooling.sh [options]

Install the conservative Fedora security tool stack used by the Phase 3
security wrappers and repair the known Lynis ownership issue if needed.

Options:
  --root <path>   Install into an alternate root and skip the root-user gate.
  --dry-run       Print the actions without executing them.
  --help          Show this help text.
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
  echo "Run this setup with sudo so it can install packages and repair host-owned files." >&2
  echo "Suggested command:" >&2
  echo "  sudo ./scripts/setup_security_tooling.sh" >&2
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

lynis_functions_path() {
  if [ -n "${ROOT_PREFIX}" ]; then
    printf '%s\n' "${ROOT_PREFIX}/usr/share/lynis/include/functions"
  else
    printf '%s\n' "/usr/share/lynis/include/functions"
  fi
}

lynis_owner_state() {
  local path
  path="$(lynis_functions_path)"
  if [ ! -e "${path}" ]; then
    printf 'missing\n'
    return 0
  fi
  stat -c '%u:%g' "${path}" 2>/dev/null || printf 'unknown\n'
}

dnf_install_args() {
  local args=(install -y)
  if [ -n "${ROOT_PREFIX}" ]; then
    args+=(--installroot "${ROOT_PREFIX}")
    if [ -n "${FEDORA_DEBUGG_RELEASEVER:-}" ]; then
      args+=(--releasever "${FEDORA_DEBUGG_RELEASEVER}")
    fi
  fi
  args+=("${PACKAGES[@]}")
  printf '%s\n' "${args[@]}"
}

main() {
  local lynis_path
  local owner_state
  local -a dnf_args

  mapfile -t dnf_args < <(dnf_install_args)
  printf 'Installing packages: %s\n' "${PACKAGES[*]}"
  run_cmd dnf "${dnf_args[@]}"

  lynis_path="$(lynis_functions_path)"
  owner_state="$(lynis_owner_state)"
  case "${owner_state}" in
    0:0)
      echo "Lynis functions ownership already correct: ${lynis_path}"
      ;;
    missing)
      echo "Lynis functions path not present yet: ${lynis_path}"
      ;;
    unknown)
      echo "Could not determine Lynis ownership: ${lynis_path}" >&2
      ;;
    *)
      echo "Repairing Lynis functions ownership (${owner_state} -> 0:0): ${lynis_path}"
      run_cmd chown 0:0 "${lynis_path}"
      ;;
  esac

  if [ -n "${ROOT_PREFIX}" ]; then
    echo "Security tooling setup completed for alternate root: ${ROOT_PREFIX}"
  else
    echo "Security tooling packages are installed."
    echo "Next step: sudo ./scripts/init_security_tooling.sh"
  fi
}

main
