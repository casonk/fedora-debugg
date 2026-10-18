#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT_PREFIX=""
TARGET_USER="${SUDO_USER:-}"
UNINSTALL=0
HELPER_PATH="/usr/local/sbin/fedora-debugg-limiter"
SUDOERS_PATH="/etc/sudoers.d/fedora-debugg-limiter"

usage() {
  cat <<'USAGE'
Usage: sudo ./scripts/install_limiter_controls.sh [--user <name>] [--root <path>] [--uninstall]

Let one user change the GPU power cap and tuned profile from a web page (the
tachometer /thermal "Set limiters" form) without a password. Installs a
root-owned copy of scripts/fedora-debugg-limiter as /usr/local/sbin/fedora-debugg-limiter,
which validates every value itself, and a sudoers rule allowing that user to
run only that file.

Options:
  --user <name>  The account allowed to use it (default: the user running sudo).
  --root <path>  Install into an alternate root and skip the visudo check.
  --uninstall    Remove the helper and the sudoers rule.
  --help         Show this help message.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --user)
      if [ $# -lt 2 ]; then
        echo "Missing value for --user" >&2
        exit 1
      fi
      TARGET_USER="$2"
      shift 2
      ;;
    --root)
      if [ $# -lt 2 ]; then
        echo "Missing value for --root" >&2
        exit 1
      fi
      ROOT_PREFIX="${2%/}"
      shift 2
      ;;
    --uninstall)
      UNINSTALL=1
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
  echo "Run this installer with sudo so it can write the helper and the sudoers rule." >&2
  exit 1
fi

helper_target="${ROOT_PREFIX}${HELPER_PATH}"
sudoers_target="${ROOT_PREFIX}${SUDOERS_PATH}"

if [ "${UNINSTALL}" -eq 1 ]; then
  rm -f "${sudoers_target}" "${helper_target}"
  echo "Removed: ${sudoers_target}"
  echo "Removed: ${helper_target}"
  exit 0
fi

if ! [[ "${TARGET_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "Pass --user <name> with a valid account name." >&2
  exit 1
fi
if [ -z "${ROOT_PREFIX}" ] && ! id -u "${TARGET_USER}" >/dev/null 2>&1; then
  echo "No such user: ${TARGET_USER}" >&2
  exit 1
fi

# A root-owned copy, so editing the checkout cannot change what sudo runs.
install -D -m 0755 "${SCRIPT_DIR}/fedora-debugg-limiter" "${helper_target}"
if [ -z "${ROOT_PREFIX}" ]; then
  chown root:root "${helper_target}"
fi
echo "Installed: ${helper_target}"

tmp_rule="$(mktemp)"
trap 'rm -f "${tmp_rule}"' EXIT
cat >"${tmp_rule}" <<RULE
# Written by fedora-debugg scripts/install_limiter_controls.sh
# ${TARGET_USER} may run the limiter helper (which validates its own arguments) and nothing else.
${TARGET_USER} ALL=(root) NOPASSWD: ${HELPER_PATH}
RULE
if [ -z "${ROOT_PREFIX}" ]; then
  visudo -cf "${tmp_rule}" >/dev/null || { echo "The generated sudoers rule failed visudo -c." >&2; exit 1; }
fi
install -D -m 0440 "${tmp_rule}" "${sudoers_target}"
echo "Installed: ${sudoers_target} (user ${TARGET_USER})"

if [ -n "${ROOT_PREFIX}" ]; then
  echo "Skipped live checks for alternate root: ${ROOT_PREFIX}"
  exit 0
fi
sudo -n -u "${TARGET_USER}" sudo -n "${HELPER_PATH}" check >/dev/null 2>&1 \
  && echo "Verified: ${TARGET_USER} can run ${HELPER_PATH} without a password." \
  || echo "Warning: could not verify the rule for ${TARGET_USER}; check 'sudo -l -U ${TARGET_USER}'." >&2
