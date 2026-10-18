#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SYS="${TMP_DIR}/sys"
PROC="${TMP_DIR}/proc"
OUT="${TMP_DIR}/out"
LOG="${TMP_DIR}/log.txt"
put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; }

put "${SYS}/class/dmi/id/board_vendor" "ASUSTeK COMPUTER INC."
put "${SYS}/class/dmi/id/board_name" "PRIME Z390-P"
put "${SYS}/class/dmi/id/bios_version" "3006"
put "${SYS}/class/dmi/id/bios_date" "10/12/2021"
put "${SYS}/class/dmi/id/board_serial" "SHOULD-NOT-APPEAR"
mkdir -p "${SYS}/firmware/efi"
put "${PROC}/cpuinfo" "model name	: Intel(R) Core(TM) i9-9900K CPU @ 3.60GHz
siblings	: 16
cpu cores	: 8
flags		: fpu hwp aes"
put "${SYS}/devices/system/cpu/intel_pstate/status" "active"
put "${SYS}/devices/system/cpu/intel_pstate/no_turbo" "0"
put "${SYS}/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq" "5000000"
put "${SYS}/devices/system/cpu/cpu0/cpuidle/state0/name" "POLL"
put "${SYS}/devices/system/cpu/cpu0/cpuidle/state1/name" "C10"
RAPL="${SYS}/class/powercap/intel-rapl:0"
put "${RAPL}/constraint_0_power_limit_uw" "95000000"
put "${RAPL}/constraint_1_power_limit_uw" "210000000"
put "${RAPL}/constraint_0_time_window_us" "27983872"
NV="${SYS}/bus/pci/devices/0000:02:00.0"
put "${NV}/class" "0x010802"
put "${NV}/vendor" "0x1987"
put "${NV}/current_link_speed" "8.0 GT/s PCIe"
put "${NV}/current_link_width" "2"
put "${NV}/max_link_speed" "16.0 GT/s PCIe"
put "${NV}/max_link_width" "4"
IG="${SYS}/bus/pci/devices/0000:00:02.0"
put "${IG}/class" "0x030000"
put "${IG}/vendor" "0x8086"
put "${IG}/current_link_width" "0"
HW="${SYS}/class/hwmon/hwmon7"
put "${HW}/name" "nct6798"
put "${HW}/pwm1_enable" "5"
put "${HW}/pwm1_mode" "1"
put "${HW}/pwm1" "193"
put "${HW}/pwm1_temp_sel" "8"
put "${HW}/fan1_input" "1051"
mkdir -p "${SYS}/class/tpm/tpm0"
put "${SYS}/class/tpm/tpm0/tpm_version_major" "2"

run() {
  FEDORA_DEBUGG_SYSFS="${SYS}" FEDORA_DEBUGG_PROCFS="${PROC}" \
    "${ROOT_DIR}/scripts/capture_firmware_profile.sh" --out-dir "${OUT}" >"${LOG}"
}

run
PROFILE="${OUT}/latest.md"
assert_file_exists "${PROFILE}"
assert_contains "${PROFILE}" "| BIOS version | 3006 |"
assert_contains "${PROFILE}" "| Boot mode | UEFI"
assert_contains "${PROFILE}" "| Hyper-Threading | enabled (8 cores / 16 threads)"
assert_contains "${PROFILE}" "| Intel VT-x | disabled (or unsupported)"
assert_contains "${PROFILE}" "| CPU power limits | PL1 95 W, PL2 210 W, tau 28 s"
assert_contains "${PROFILE}" "| Integrated GPU | enabled (0000:00:02.0)"
assert_contains "${PROFILE}" "8.0 GT/s PCIe x2 (device max 16.0 GT/s PCIe x4"
assert_contains "${PROFILE}" "SmartFan IV (BIOS fan curve), PWM, duty 193/255"
assert_contains "${PROFILE}" "| TPM | enabled, TPM 2.x"
assert_contains "${PROFILE}" "## Record by hand"
if grep -q "SHOULD-NOT-APPEAR" "${PROFILE}"; then
  echo "serial numbers must never be recorded" >&2
  exit 1
fi
if grep -q "PCIe link 0000:00:02.0" "${PROFILE}"; then
  echo "integrated devices without a link must be skipped" >&2
  exit 1
fi

sleep 1
put "${HW}/fan1_input" "1400"   # live readings alone are not a settings change
put "${HW}/pwm1" "120"
run
assert_contains "${LOG}" "No setting changes since"
assert_contains "${LOG}" "kept it as latest"
if [ "$(ls "${OUT}"/firmware-profile-*.md | wc -l)" -ne 1 ]; then
  echo "an unchanged capture must not be kept as a second file" >&2
  exit 1
fi

sleep 1
put "${SYS}/class/dmi/id/bios_version" "3007"   # as after a BIOS update or reset
put "${HW}/pwm1_enable" "0"
run
assert_contains "${LOG}" "Changed since"
assert_contains "${LOG}" "before: | BIOS version | 3006"
assert_contains "${LOG}" "now:    | BIOS version | 3007"
assert_contains "${LOG}" "off / full speed"

# A root capture adds [root] rows; a later unprivileged run must not report them as removed.
sleep 1
latest="$(readlink -f "${OUT}/latest.md")"
printf '| DIMM A | 32 GB, configured 2666 MT/s; XMP off | part X [root] |\n' >>"${latest}"
run
assert_contains "${LOG}" "No setting changes since"
