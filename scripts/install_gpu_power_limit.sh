#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ROOT_PREFIX=""
WATTS=""
UNINSTALL=0
UNIT_NAME="fedora-debugg-gpu-power-limit.service"
CONF_PATH="/etc/fedora-debugg/gpu-power-limit.conf"

usage() {
  cat <<'USAGE'
Usage: sudo ./scripts/install_gpu_power_limit.sh [--watts <W>] [--root <path>] [--uninstall]

Persist an NVIDIA GPU power cap across reboots. Installs a oneshot systemd unit
that runs `nvidia-smi --power-limit` at boot from /etc/fedora-debugg/gpu-power-limit.conf,
enables nvidia-persistenced so the driver keeps the setting, and applies the
cap immediately. Re-run with a different --watts to change it.

Options:
  --watts <W>    Power limit in watts (default: keep the configured value, else 250).
  --root <path>  Install into an alternate root and skip systemctl.
  --uninstall    Remove the unit and config, and restore the default limit.
  --help         Show this help message.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --watts)
      if [ $# -lt 2 ]; then
        echo "Missing value for --watts" >&2
        exit 1
      fi
      WATTS="$2"
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
  echo "Run this installer with sudo so it can write systemd units and set the GPU power limit." >&2
  exit 1
fi

unit_target="${ROOT_PREFIX}/etc/systemd/system/${UNIT_NAME}"
conf_target="${ROOT_PREFIX}${CONF_PATH}"

# Reads one "Min/Max/Default Power Limit" value in whole watts from nvidia-smi.
gpu_limit() {
  nvidia-smi -q -d POWER 2>/dev/null \
    | awk -F': ' -v key="$1" '$1 ~ key && $2 ~ /W$/ { split($2, v, "."); print v[1]; exit }'
}

if [ "${UNINSTALL}" -eq 1 ]; then
  if [ -z "${ROOT_PREFIX}" ]; then
    systemctl disable --now "${UNIT_NAME}" 2>/dev/null || true
  fi
  rm -f "${unit_target}" "${conf_target}"
  echo "Removed: ${unit_target}"
  echo "Removed: ${conf_target}"
  if [ -z "${ROOT_PREFIX}" ]; then
    systemctl daemon-reload
    default_w="$(gpu_limit "Default Power Limit")"
    if [ -n "${default_w}" ]; then
      nvidia-smi --power-limit="${default_w}" >/dev/null && echo "Restored the default limit: ${default_w} W"
    fi
  fi
  exit 0
fi

if [ -z "${WATTS}" ] && [ -f "${conf_target}" ]; then
  WATTS="$(sed -n 's/^GPU_POWER_LIMIT_W=//p' "${conf_target}")"
fi
WATTS="${WATTS:-250}"

case "${WATTS}" in
  ''|*[!0-9]*)
    echo "--watts must be a whole number of watts, got: ${WATTS}" >&2
    exit 1
    ;;
esac

if [ -z "${ROOT_PREFIX}" ]; then
  min_w="$(gpu_limit "Min Power Limit")"
  max_w="$(gpu_limit "Max Power Limit")"
  if [ -n "${min_w}" ] && [ -n "${max_w}" ] \
    && { [ "${WATTS}" -lt "${min_w}" ] || [ "${WATTS}" -gt "${max_w}" ]; }; then
    echo "${WATTS} W is outside this GPU's range of ${min_w}-${max_w} W." >&2
    exit 1
  fi
fi

source_unit="${ROOT_DIR}/config/gpu-power-limit/${UNIT_NAME}"
if [ -e "${unit_target}" ] && cmp -s "${source_unit}" "${unit_target}"; then
  echo "Already installed: ${unit_target}"
else
  install -D -m 0644 "${source_unit}" "${unit_target}"
  echo "Installed: ${unit_target}"
fi

install -d -m 0755 "$(dirname "${conf_target}")"
printf '# Written by fedora-debugg scripts/install_gpu_power_limit.sh\nGPU_POWER_LIMIT_W=%s\n' \
  "${WATTS}" >"${conf_target}"
chmod 0644 "${conf_target}"
echo "Configured: ${conf_target} (GPU_POWER_LIMIT_W=${WATTS})"

if [ -n "${ROOT_PREFIX}" ]; then
  echo "Skipped systemctl for alternate root: ${ROOT_PREFIX}"
  exit 0
fi

systemctl daemon-reload
if systemctl list-unit-files nvidia-persistenced.service >/dev/null 2>&1; then
  systemctl enable --now nvidia-persistenced.service
fi
systemctl enable "${UNIT_NAME}"
# restart so a changed --watts takes effect now, not only at the next boot
systemctl restart "${UNIT_NAME}"
nvidia-smi -q -d POWER | grep -E "Current Power Limit" | head -1
echo "The GPU power limit is ${WATTS} W now and at every boot."
