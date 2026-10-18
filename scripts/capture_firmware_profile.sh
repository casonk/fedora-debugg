#!/usr/bin/env bash
# Infer the BIOS/UEFI configuration from what Linux can observe, so the settings
# can be restored after an unexpected CMOS reset (or a BIOS update that resets
# them), and so a later capture shows exactly what changed.
#
# Writes local/firmware/firmware-profile-<timestamp>.md (gitignored: this repo is
# public), points local/firmware/latest.md at it, and prints the settings that
# differ from the previous capture. Serial numbers and UUIDs are never recorded.
# Runs unprivileged; with sudo it also reads memory/XMP and PCIe ASPM details.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${FEDORA_DEBUGG_FIRMWARE_DIR:-${ROOT_DIR}/local/firmware}"
SYS="${FEDORA_DEBUGG_SYSFS:-/sys}"
PROC="${FEDORA_DEBUGG_PROCFS:-/proc}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/capture_firmware_profile.sh [--out-dir <dir>]
       sudo ./scripts/capture_firmware_profile.sh   # adds memory/XMP and PCIe ASPM detail

Record the BIOS settings Linux can infer (boot mode, Secure Boot, CPU features,
power limits, C-states, iGPU, Resizable BAR, PCIe link widths, SATA mode and
ports, fan control modes, TPM) with the evidence for each, and compare with the
previous capture. Output stays in the gitignored local/firmware/.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir)
      [ $# -ge 2 ] || { echo "Missing value for --out-dir" >&2; exit 1; }
      OUT_DIR="$2"
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

read_file() {
  local value
  value="$(cat "$1" 2>/dev/null | head -n1)" || true
  printf '%s' "${value}" | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

ROWS=()
row() {
  # setting | value | evidence
  ROWS+=("| $1 | $2 | $3 |")
}

section() {
  ROWS+=("" "## $1" "" "| Setting | Inferred value | Evidence |" "|---|---|---|")
}

# --- Board and firmware -------------------------------------------------------
dmi="${SYS}/class/dmi/id"
section "Board and firmware"
row "Board" "$(read_file "${dmi}/board_vendor") $(read_file "${dmi}/board_name")" "dmi board_vendor/board_name"
row "BIOS version" "$(read_file "${dmi}/bios_version")" "dmi bios_version"
row "BIOS date" "$(read_file "${dmi}/bios_date")" "dmi bios_date"

# --- Boot ---------------------------------------------------------------------
section "Boot"
if [ -d "${SYS}/firmware/efi" ]; then
  row "Boot mode" "UEFI (CSM not used for this boot)" "/sys/firmware/efi present"
else
  row "Boot mode" "Legacy/CSM" "/sys/firmware/efi absent"
fi
sb_var="$(ls "${SYS}"/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -n1)"
if [ -n "${sb_var}" ]; then
  sb="$(od -An -t u1 "${sb_var}" 2>/dev/null | awk '{print $NF}')"
  row "Secure Boot" "$([ "${sb}" = 1 ] && echo enabled || echo disabled)" "SecureBoot efivar = ${sb}"
fi
if command -v efibootmgr >/dev/null 2>&1; then
  order="$(efibootmgr 2>/dev/null | sed -n 's/^BootOrder: //p')"
  first="$(efibootmgr 2>/dev/null | awk -v b="$(efibootmgr 2>/dev/null | sed -n 's/^BootOrder: \([0-9A-F]*\).*/\1/p')" '$1 ~ "^Boot" b {sub(/^Boot[0-9A-F]+\*? /, ""); sub(/\t.*/, ""); print; exit}')"
  row "Boot order" "${order:-unknown} (first: ${first:-?})" "efibootmgr"
  row "Boot menu timeout" "$(efibootmgr 2>/dev/null | sed -n 's/^Timeout: //p')" "efibootmgr"
fi

# --- CPU ----------------------------------------------------------------------
cpu="${SYS}/devices/system/cpu"
cpuinfo="${PROC}/cpuinfo"
section "CPU"
row "Processor" "$(grep -m1 'model name' "${cpuinfo}" | cut -d: -f2- | sed 's/^ //')" "/proc/cpuinfo"
siblings="$(grep -m1 '^siblings' "${cpuinfo}" | awk '{print $3}')"
cores="$(grep -m1 '^cpu cores' "${cpuinfo}" | awk '{print $4}')"
row "Hyper-Threading" "$([ "${siblings:-0}" -gt "${cores:-0}" ] && echo enabled || echo disabled) (${cores} cores / ${siblings} threads)" "/proc/cpuinfo siblings vs cpu cores"
if grep -qw vmx "${cpuinfo}"; then
  row "Intel VT-x" "enabled" "vmx CPU flag present"
else
  row "Intel VT-x" "disabled (or unsupported)" "no vmx CPU flag"
fi
if journalctl -k -b --no-pager 2>/dev/null | grep -qE 'DMAR: (IOMMU enabled|Host address width)'; then
  row "Intel VT-d" "enabled" "kernel log has a DMAR table"
elif [ -n "$(ls "${SYS}/class/iommu" 2>/dev/null)" ]; then
  row "Intel VT-d" "enabled" "/sys/class/iommu has units"
else
  row "Intel VT-d" "disabled" "no DMAR table / no IOMMU units"
fi
row "Speed Shift (HWP)" "$(grep -qw hwp "${cpuinfo}" && echo enabled || echo disabled)" "hwp CPU flag; intel_pstate $(read_file "${cpu}/intel_pstate/status")"
hw_max="$(read_file "${cpu}/cpu0/cpufreq/cpuinfo_max_freq")"
row "Turbo Boost" "$([ "$(read_file "${cpu}/intel_pstate/no_turbo")" = 0 ] && echo "enabled (max ${hw_max:-?} kHz)" || echo "disabled now (may be the OS, e.g. tuned powersave)")" "intel_pstate/no_turbo"
states="$(for s in "${cpu}"/cpu0/cpuidle/state*/name; do read_file "${s}"; printf ' '; done)"
row "C-states" "${states:-none listed}" "cpu0/cpuidle state names (deepest enabled in BIOS appears last)"
rapl="${SYS}/class/powercap/intel-rapl:0"
if [ -d "${rapl}" ]; then
  pl1=$(( $(read_file "${rapl}/constraint_0_power_limit_uw") / 1000000 ))
  pl2=$(( $(read_file "${rapl}/constraint_1_power_limit_uw") / 1000000 ))
  tau="$(awk -v us="$(read_file "${rapl}/constraint_0_time_window_us")" 'BEGIN{printf "%.0f", us/1e6}')"
  row "CPU power limits" "PL1 ${pl1} W, PL2 ${pl2} W, tau ${tau} s" "RAPL package-0 (BIOS power limits / MultiCore Enhancement)"
fi

# --- Graphics and PCIe --------------------------------------------------------
section "Graphics and PCIe"
pci="${SYS}/bus/pci/devices"
igpu="$(for d in "${pci}"/*; do [ "$(read_file "${d}/class")" = 0x030000 ] && [ "$(read_file "${d}/vendor")" = 0x8086 ] && basename "${d}"; done | head -n1)"
row "Integrated GPU" "$([ -n "${igpu}" ] && echo "enabled (${igpu})" || echo "disabled or absent")" "Intel VGA function on the PCI bus"
for d in "${pci}"/*; do
  class="$(read_file "${d}/class")"
  case "${class}" in
    0x030000|0x030200) ;;
    *) continue ;;
  esac
  [ "$(read_file "${d}/vendor")" = 0x8086 ] && continue
  bar1="$(awk 'NR==2 {s=strtonum($1); e=strtonum($2); if (e > s) printf "%d", (e - s + 1) / 1048576}' "${d}/resource" 2>/dev/null)"
  bar0="$(awk 'NR==1 {s=strtonum($1); e=strtonum($2); if (e > s) printf "%d", (e - s + 1) / 1048576}' "${d}/resource" 2>/dev/null)"
  largest="$(printf '%s\n%s\n' "${bar0:-0}" "${bar1:-0}" | sort -n | tail -n1)"
  if [ "${largest:-0}" -gt 256 ]; then
    rebar="enabled (largest BAR ${largest} MiB)"
  else
    rebar="disabled (largest BAR ${largest:-?} MiB)"
  fi
  row "Resizable BAR / Above 4G ($(basename "${d}"))" "${rebar}" "discrete GPU BAR sizes"
done
for d in "${pci}"/*; do
  [ -r "${d}/current_link_width" ] || continue
  # Integrated devices report width 0 (no external link).
  [ "$(read_file "${d}/current_link_width")" = 0 ] && continue
  class="$(read_file "${d}/class")"
  case "${class}" in
    0x010802|0x030000|0x030200|0x020000|0x010601) ;;
    *) continue ;;
  esac
  name="$(lspci -s "$(basename "${d}")" 2>/dev/null | cut -d' ' -f2- | cut -c1-60)"
  port="$(basename "$(dirname "$(readlink -f "${d}")")")"
  cur="$(read_file "${d}/current_link_speed") x$(read_file "${d}/current_link_width")"
  max="$(read_file "${d}/max_link_speed") x$(read_file "${d}/max_link_width")"
  pmax="$(read_file "${pci}/${port}/max_link_speed") x$(read_file "${pci}/${port}/max_link_width")"
  row "PCIe link $(basename "${d}")" "${cur} (device max ${max}; port ${port} max ${pmax})" "${name:-class ${class}}"
done
row "ASPM policy" "$(sed -n 's/.*\[\(.*\)\].*/\1/p' "${SYS}/module/pcie_aspm/parameters/policy" 2>/dev/null)" "pcie_aspm policy (BIOS may also disable ASPM per link; see lspci -vv with sudo)"

# --- Storage ------------------------------------------------------------------
section "Storage"
for d in "${pci}"/*; do
  case "$(read_file "${d}/class")" in
    0x010601) row "SATA controller mode" "AHCI ($(basename "${d}"))" "PCI class 0x010601" ;;
    0x010400) row "SATA controller mode" "RAID/RST ($(basename "${d}"))" "PCI class 0x010400" ;;
  esac
done
for blk in "${SYS}"/block/sd*; do
  [ -e "${blk}" ] || continue
  path="$(readlink -f "${blk}/device")"
  port="$(printf '%s' "${path}" | grep -oE 'ata[0-9]+' | head -n1)"
  usb="$(printf '%s' "${path}" | grep -q '/usb' && echo yes || echo no)"
  model="$(read_file "${blk}/device/model")"
  if [ "${usb}" = yes ]; then
    row "Drive $(basename "${blk}")" "USB (${model})" "sysfs device path"
  else
    row "Drive $(basename "${blk}")" "SATA port ${port:-?} (${model})" "sysfs device path (ataN is the controller port number, 1-based)"
  fi
done

# --- Fans ---------------------------------------------------------------------
section "Fan control (Q-Fan)"
for chip in "${SYS}"/class/hwmon/hwmon*; do
  ls "${chip}"/pwm[0-9]*_enable >/dev/null 2>&1 || continue
  chip_name="$(read_file "${chip}/name")"
  for enable in "${chip}"/pwm[0-9]*_enable; do
    n="$(basename "${enable}" | sed 's/^pwm\([0-9]*\)_enable$/\1/')"
    mode="$(read_file "${enable}")"
    case "${mode}" in
      0) meaning="off / full speed" ;;
      1) meaning="manual (fixed duty)" ;;
      2) meaning="thermal cruise" ;;
      3) meaning="fan speed cruise" ;;
      4) meaning="SmartFan III" ;;
      5) meaning="SmartFan IV (BIOS fan curve)" ;;
      *) meaning="mode ${mode}" ;;
    esac
    signal="$([ "$(read_file "${chip}/pwm${n}_mode")" = 1 ] && echo PWM || echo DC)"
    rpm="$(read_file "${chip}/fan${n}_input")"
    row "${chip_name} fan header ${n}" "${meaning}, ${signal}, duty $(read_file "${chip}/pwm${n}")/255, temp source $(read_file "${chip}/pwm${n}_temp_sel")" "pwm${n}_enable=${mode}; fan${n} ${rpm:-?} rpm"
  done
done

# --- Security -----------------------------------------------------------------
section "Security"
if [ -d "${SYS}/class/tpm/tpm0" ]; then
  row "TPM" "enabled, TPM $(read_file "${SYS}/class/tpm/tpm0/tpm_version_major").x" "/sys/class/tpm/tpm0 (Intel PTT or a discrete module)"
else
  row "TPM" "disabled or absent" "no /sys/class/tpm/tpm0"
fi

# --- Root-only detail ---------------------------------------------------------
if [ "${EUID}" -eq 0 ]; then
  section "Memory (needs root)"
  if command -v dmidecode >/dev/null 2>&1; then
    while IFS= read -r line; do ROWS+=("${line}"); done < <(dmidecode -t 17 2>/dev/null | awk -F': ' '
      /^Memory Device/ { slot=""; size=""; speed=""; conf=""; part="" }
      /^\tLocator:/ { slot=$2 } /^\tSize:/ { size=$2 } /^\tSpeed:/ { speed=$2 }
      /^\tConfigured Memory Speed:/ { conf=$2 } /^\tPart Number:/ { gsub(/ +$/, "", $2); part=$2 }
      /^\tConfigured Voltage:/ { if (size !~ /No Module/) printf "| DIMM %s | %s, configured %s (rated %s) | part %s, %s; XMP is on when configured equals a rated speed above JEDEC 2133/2666 |\n", slot, size, conf, speed, part, $2 }')
  fi
  section "PCIe ASPM per link (needs root)"
  while IFS= read -r line; do ROWS+=("${line}"); done < <(lspci -vv 2>/dev/null | awk '
    /^[0-9a-f]+:[0-9a-f]+\.[0-9]/ { dev=$1 }
    /LnkCtl:/ { if (match($0, /ASPM [^;]*/)) printf "| ASPM %s | %s | lspci -vv LnkCtl |\n", dev, substr($0, RSTART, RLENGTH) }')
fi

# --- Write --------------------------------------------------------------------
stamp="$(date +%Y%m%d-%H%M%S)"
mkdir -p "${OUT_DIR}"
out="${OUT_DIR}/firmware-profile-${stamp}.md"
previous="$(ls "${OUT_DIR}"/firmware-profile-*.md 2>/dev/null | sort | tail -n1)"
{
  echo "# Firmware profile $(date -Iseconds)"
  echo
  echo "Inferred from Linux by fedora-debugg scripts/capture_firmware_profile.sh"
  echo "$([ "${EUID}" -eq 0 ] && echo "(run as root: memory and ASPM detail included)" || echo "(run unprivileged; re-run with sudo for memory/XMP and ASPM detail)")."
  printf '%s\n' "${ROWS[@]}"
  cat <<'NOTES'

## Record by hand (Linux cannot see these)

- Restore on AC power loss, ErP / deep sleep, Wake-on-LAN and power-on by PCIe/USB
- Q-Fan curve points (temperatures and duty per header), only the modes are visible above
- PCIe slot bandwidth / M.2 lane-sharing options, PCIEX16_x mode, onboard SATA port enables
- XMP profile choice and any manual memory timings or voltages
- CPU core voltage / load-line, and any overclocking or undervolting
- Fast Boot, boot logo, CSM details, and the BIOS admin/user passwords' existence
- TPM-sealed secrets: LUKS volumes unlocked through clevis/TPM2 can stop auto-unlocking
  after a CMOS reset or BIOS update changes the measured PCRs; keep the LUKS passphrases
  (ignition) at hand before touching firmware.
NOTES
} >"${out}"
ln -sfn "$(basename "${out}")" "${OUT_DIR}/latest.md"

if [ -z "${previous}" ] || [ "${previous}" = "${out}" ]; then
  echo "Wrote ${out}"
else
  echo "Wrote ${out}"
  # Live readings (fan duty and RPM) change constantly; mask them so only settings count.
  settings() {
    grep '^| ' "$1" | grep -v '^| Setting' \
      | sed -E 's/duty [0-9]+\/255/duty -\/255/; s/(fan[0-9]+) [0-9?]+ rpm/\1 - rpm/'
  }
  changes="$(diff <(settings "${previous}") <(settings "${out}") | grep -E '^[<>]' || true)"
  if [ -n "${changes}" ]; then
    echo "Changed since $(basename "${previous}"):"
    printf '%s\n' "${changes}" | sed 's/^</  before:/; s/^>/  now:   /'
  elif [ "$(grep -c '^| ' "${out}")" -le "$(grep -c '^| ' "${previous}")" ]; then
    # Nothing changed: keep the earlier capture as the record instead of piling up copies.
    # (A capture with more rows, e.g. the first one run with sudo, is kept.)
    rm -f "${out}"
    ln -sfn "$(basename "${previous}")" "${OUT_DIR}/latest.md"
    echo "No setting changes since $(basename "${previous}"); kept it as latest."
  else
    echo "No setting changes since $(basename "${previous}"); kept the new, more detailed capture."
  fi
fi
