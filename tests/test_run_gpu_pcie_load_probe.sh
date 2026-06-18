#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

assert_file_exists() {
  if [ ! -f "$1" ]; then
    echo "FAIL: expected file $1" >&2
    exit 1
  fi
}

assert_contains() {
  local file="$1"
  local expected="$2"
  if ! grep -Fq -- "${expected}" "${file}"; then
    echo "FAIL: expected '${expected}' in ${file}" >&2
    exit 1
  fi
}

SNAPSHOT_DIR="${TMP_DIR}/snapshot-fixture"
COMMANDS_DIR="${SNAPSHOT_DIR}/commands"
SYSFS_ROOT="${TMP_DIR}/sysfs"
GPU_DIR="${SYSFS_ROOT}/0000:03:00.0"
mkdir -p "${COMMANDS_DIR}" "${GPU_DIR}/driver"
ln -s /lib/modules/mock-nvidia "${GPU_DIR}/driver/module"

cat >"${GPU_DIR}/class" <<'EOF'
0x030000
EOF
cat >"${GPU_DIR}/vendor" <<'EOF'
0x10de
EOF
cat >"${GPU_DIR}/device" <<'EOF'
0x2204
EOF
cat >"${GPU_DIR}/subsystem_vendor" <<'EOF'
0x3842
EOF
cat >"${GPU_DIR}/subsystem_device" <<'EOF'
0x3982
EOF
cat >"${GPU_DIR}/current_link_speed" <<'EOF'
2.5 GT/s PCIe
EOF
cat >"${GPU_DIR}/current_link_width" <<'EOF'
4
EOF
cat >"${GPU_DIR}/max_link_speed" <<'EOF'
16.0 GT/s PCIe
EOF
cat >"${GPU_DIR}/max_link_width" <<'EOF'
16
EOF

OUTPUT_PATH="${COMMANDS_DIR}/gpu-pcie-load-probe.txt"
env -u DISPLAY -u WAYLAND_DISPLAY \
  FEDORA_DEBUGG_GPU_PCIE_SYSFS_ROOT="${SYSFS_ROOT}" \
  "${ROOT_DIR}/scripts/run_gpu_pcie_load_probe.sh" \
  --snapshot-dir "${SNAPSHOT_DIR}" \
  --duration 1 \
  --interval 1 \
  --output "${OUTPUT_PATH}" >/dev/null

assert_file_exists "${OUTPUT_PATH}"
assert_contains "${OUTPUT_PATH}" "workload_status=skipped"
assert_contains "${OUTPUT_PATH}" "result_pcie_link_count=1"
assert_contains "${OUTPUT_PATH}" "result_width_degraded_before=1"
assert_contains "${OUTPUT_PATH}" "result_width_degraded_during=1"
assert_contains "${OUTPUT_PATH}" "result_max_observed_width=4"
assert_contains "${OUTPUT_PATH}" "result_max_cap_width=16"
assert_contains "${OUTPUT_PATH}" "pci_device=0000:03:00.0"
