#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ROOT_PREFIX=""
UNINSTALL=0
RULE_NAME="61-fedora-debugg-io-tuning.rules"

usage() {
  cat <<'USAGE'
Usage: sudo ./scripts/install_io_tuning.sh [--root <path>] [--uninstall]

Install udev rules that pick the I/O scheduler and read-ahead by drive type:
NVMe -> none, SATA/SAS SSD -> mq-deadline, hard drive -> bfq with 8 MiB
read-ahead. They apply to every disk now and to any disk added later.

Options:
  --root <path>  Install into an alternate root and skip udevadm.
  --uninstall    Remove the rules (Fedora's defaults return on the next boot).
  --help         Show this help message.
USAGE
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
  echo "Run this installer with sudo so it can write udev rules." >&2
  exit 1
fi

rule_target="${ROOT_PREFIX}/etc/udev/rules.d/${RULE_NAME}"

if [ "${UNINSTALL}" -eq 1 ]; then
  rm -f "${rule_target}"
  echo "Removed: ${rule_target}"
  if [ -z "${ROOT_PREFIX}" ]; then
    udevadm control --reload
    echo "Fedora's default schedulers return on the next boot or device change."
  fi
  exit 0
fi

source_rule="${ROOT_DIR}/config/io-tuning/${RULE_NAME}"
if [ -e "${rule_target}" ] && cmp -s "${source_rule}" "${rule_target}"; then
  echo "Already installed: ${rule_target}"
else
  install -D -m 0644 "${source_rule}" "${rule_target}"
  echo "Installed: ${rule_target}"
fi

if [ -n "${ROOT_PREFIX}" ]; then
  echo "Skipped udevadm for alternate root: ${ROOT_PREFIX}"
  exit 0
fi

udevadm control --reload
udevadm trigger --subsystem-match=block --action=change
udevadm settle
for queue in /sys/block/*/queue; do
  disk="$(basename "$(dirname "${queue}")")"
  case "${disk}" in
    loop*|zram*|dm-*|sr*) continue ;;
  esac
  scheduler="$(sed -n 's/.*\[\(.*\)\].*/\1/p' "${queue}/scheduler")"
  printf '%-10s scheduler=%-12s read_ahead=%s KiB\n' \
    "${disk}" "${scheduler:-none}" "$(cat "${queue}/read_ahead_kb")"
done
