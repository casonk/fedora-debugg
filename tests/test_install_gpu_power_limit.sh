#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ALT_ROOT="${TMP_DIR}/root"
OUTPUT_FILE="${TMP_DIR}/output.txt"
UNIT="${ALT_ROOT}/etc/systemd/system/fedora-debugg-gpu-power-limit.service"
CONF="${ALT_ROOT}/etc/fedora-debugg/gpu-power-limit.conf"
INSTALLER="${ROOT_DIR}/scripts/install_gpu_power_limit.sh"

"${INSTALLER}" --root "${ALT_ROOT}" >"${OUTPUT_FILE}"
assert_file_exists "${UNIT}"
assert_contains "${UNIT}" 'ExecStart=/usr/bin/nvidia-smi --power-limit=${GPU_POWER_LIMIT_W}'
assert_contains "${UNIT}" "After=nvidia-persistenced.service"
assert_contains "${CONF}" "GPU_POWER_LIMIT_W=250"
assert_contains "${OUTPUT_FILE}" "Skipped systemctl for alternate root"

# A new wattage rewrites the config; the unit stays as installed.
"${INSTALLER}" --root "${ALT_ROOT}" --watts 220 >"${OUTPUT_FILE}"
assert_contains "${CONF}" "GPU_POWER_LIMIT_W=220"
assert_contains "${OUTPUT_FILE}" "Already installed:"

# Without --watts the configured value is kept.
"${INSTALLER}" --root "${ALT_ROOT}" >"${OUTPUT_FILE}"
assert_contains "${CONF}" "GPU_POWER_LIMIT_W=220"

if "${INSTALLER}" --root "${ALT_ROOT}" --watts 25O >"${OUTPUT_FILE}" 2>&1; then
  echo "expected a non-numeric wattage to be rejected" >&2
  exit 1
fi
assert_contains "${OUTPUT_FILE}" "must be a whole number"

"${INSTALLER}" --root "${ALT_ROOT}" --uninstall >"${OUTPUT_FILE}"
if [ -e "${UNIT}" ] || [ -e "${CONF}" ]; then
  echo "expected --uninstall to remove the unit and config" >&2
  exit 1
fi
