#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT_BASE="${ROOT_DIR}/artifacts"
PATH_ONLY=0
TOP_DEPTH=1
TOP_LIMIT=8
SCAN_ALL_MOUNTS=0
TARGET_USER=""
TARGET_HOME=""
TOP_PATH_TARGETS=""
CLEANUP_PATHS=""
DEVICE_PATHS=""
FWUPD_TIMEOUT=20

usage() {
  cat <<'EOF'
Usage: ./scripts/analyze_storage_hardware.sh [options]

Analyze filesystem usage, cleanup candidates, storage layout, and firmware/drive
health signals.

Options:
  --output-dir <dir>    Output base directory (default: ./artifacts).
  --top-depth <n>       du depth for top-path scans (default: 1).
  --top-limit <n>       Maximum rows per top-path scan (default: 8).
  --scan-all-mounts     Collect top-path scans for every real filesystem mount.
  --path-only           Print only the generated report path.
  --help                Show this help message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --output-dir)
      [ $# -lt 2 ] && { echo "Missing value for --output-dir" >&2; exit 1; }
      OUTPUT_BASE="$2"
      shift 2
      ;;
    --top-depth)
      [ $# -lt 2 ] && { echo "Missing value for --top-depth" >&2; exit 1; }
      TOP_DEPTH="$2"
      shift 2
      ;;
    --top-limit)
      [ $# -lt 2 ] && { echo "Missing value for --top-limit" >&2; exit 1; }
      TOP_LIMIT="$2"
      shift 2
      ;;
    --scan-all-mounts)
      SCAN_ALL_MOUNTS=1
      shift
      ;;
    --path-only)
      PATH_ONLY=1
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

case "${OUTPUT_BASE}" in
  /*) ;;
  *) OUTPUT_BASE="${ROOT_DIR}/${OUTPUT_BASE}" ;;
esac

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="${OUTPUT_BASE}/storage-audit-${TIMESTAMP}"
COMMANDS_DIR="${REPORT_DIR}/commands"
TABLES_DIR="${REPORT_DIR}/tables"
STATUS_FILE="${COMMANDS_DIR}/command-status.tsv"
SUMMARY_FILE="${REPORT_DIR}/storage-summary.md"

mkdir -p "${COMMANDS_DIR}" "${TABLES_DIR}"

log() {
  if [ "${PATH_ONLY}" -eq 0 ]; then
    printf '[storage] %s\n' "$*"
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sanitize_field() {
  local value="${1:-}"
  value="${value//$'\t'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  printf '%s' "${value}"
}

record_command_status() {
  local file_name="$1"
  local status="$2"
  shift 2
  local cmd=("$@")
  {
    printf '%s\t%s\t' "${file_name}" "${status}"
    printf '%q ' "${cmd[@]}"
    printf '\n'
  } >>"${STATUS_FILE}"
}

write_cmd_output() {
  local file_name="$1"
  shift
  local out_file="${COMMANDS_DIR}/${file_name}"
  local err_file="${out_file}.stderr"
  local cmd=("$@")
  local status

  : >"${out_file}"
  rm -f "${err_file}"

  if ! has_cmd "${cmd[0]}"; then
    record_command_status "${file_name}" "127" "${cmd[@]}"
    return 0
  fi

  "${cmd[@]}" >"${out_file}" 2>"${err_file}"
  status=$?
  record_command_status "${file_name}" "${status}" "${cmd[@]}"
  if [ ! -s "${err_file}" ]; then
    rm -f "${err_file}"
  fi
  return 0
}

write_cmd_output_with_timeout() {
  local file_name="$1"
  local timeout_seconds="$2"
  shift 2
  local out_file="${COMMANDS_DIR}/${file_name}"
  local err_file="${out_file}.stderr"
  local cmd=("$@")
  local status

  : >"${out_file}"
  rm -f "${err_file}"

  if ! has_cmd "${cmd[0]}"; then
    record_command_status "${file_name}" "127" "${cmd[@]}"
    return 0
  fi

  if has_cmd timeout; then
    timeout "${timeout_seconds}" "${cmd[@]}" >"${out_file}" 2>"${err_file}"
    status=$?
  else
    "${cmd[@]}" >"${out_file}" 2>"${err_file}"
    status=$?
  fi

  record_command_status "${file_name}" "${status}" "${cmd[@]}"
  if [ ! -s "${err_file}" ]; then
    rm -f "${err_file}"
  fi
  return 0
}

has_text_in_output() {
  local pattern="$1"
  local file="$2"
  grep -Eiq "${pattern}" "${file}" "${file}.stderr" 2>/dev/null
}

filtered_output_lines() {
  local file="$1"
  local limit="${2:-10}"
  awk '
    NF == 0 { next }
    /dconf-CRITICAL/ { next }
    { print }
  ' "${file}" "${file}.stderr" 2>/dev/null | sed -n "1,${limit}p"
}

human_bytes() {
  local bytes="${1:-0}"
  awk -v bytes="${bytes}" '
    BEGIN {
      split("B KiB MiB GiB TiB", units, " ")
      idx = 1
      while (bytes >= 1024 && idx < 5) {
        bytes /= 1024
        idx++
      }
      if (idx == 1) {
        printf "%.0f %s", bytes, units[idx]
      } else {
        printf "%.1f %s", bytes, units[idx]
      }
    }
  '
}

safe_slug() {
  printf '%s\n' "$1" | sed 's#[^[:alnum:]]#-#g'
}

resolve_target_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    TARGET_USER="${SUDO_USER}"
  elif [ -n "${USER:-}" ]; then
    TARGET_USER="${USER}"
  else
    TARGET_USER="unknown"
  fi

  TARGET_HOME="$(getent passwd "${TARGET_USER}" 2>/dev/null | awk -F: '{print $6}')"
  if [ -z "${TARGET_HOME}" ]; then
    TARGET_HOME="${HOME:-/home/${TARGET_USER}}"
  fi
}

kv_value() {
  local line="$1"
  local key="$2"
  printf '%s\n' "${line}" | sed -n "s/.*${key}=\"\\([^\"]*\\)\".*/\\1/p"
}

write_du_scan() {
  local file_name="$1"
  local target="$2"
  local target_q

  printf -v target_q '%q' "${target}"
  write_cmd_output "${file_name}" bash -lc "du -x -B1 -d ${TOP_DEPTH} ${target_q} 2>/dev/null | sort -nr | sed -n '1,$((TOP_LIMIT + 1))p'"
}

dir_size_bytes() {
  local path="$1"
  local output

  [ -e "${path}" ] || { echo "0"; return 0; }
  output="$(du -sx -B1 "${path}" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
  printf '%s\n' "${output:-0}"
}

cleanup_category() {
  local path="$1"
  case "${path}" in
    */.local/share/Trash|*/.local/share/Trash/*) echo "trash" ;;
    */.cache|*/.cache/*) echo "user-cache" ;;
    /var/cache/dnf|/var/cache/PackageKit|/var/cache/akmods|/var/tmp) echo "system-cache" ;;
    /var/log/journal) echo "journal" ;;
    /var/lib/systemd/coredump) echo "coredumps" ;;
    *) echo "review" ;;
  esac
}

cleanup_hint() {
  local category="$1"
  case "${category}" in
    trash|user-cache|system-cache|coredumps) echo "high" ;;
    journal) echo "medium" ;;
    *) echo "review" ;;
  esac
}

is_real_filesystem() {
  case "$1" in
    btrfs|bcachefs|ext2|ext3|ext4|f2fs|vfat|xfs|zfs|zfs_member) return 0 ;;
    *) return 1 ;;
  esac
}

mount_pressure() {
  local pct="${1%\%}"
  if [ "${pct:-0}" -ge 90 ]; then
    echo "high"
  elif [ "${pct:-0}" -ge 80 ]; then
    echo "medium"
  else
    echo "normal"
  fi
}

smart_health_from_file() {
  local file="$1"
  [ -f "${file}" ] || { echo "unknown"; return 0; }
  if has_text_in_output 'PASSED|SMART Health Status: OK' "${file}"; then
    echo "passed"
  elif has_text_in_output 'permission denied|operation not permitted' "${file}"; then
    echo "restricted"
  elif has_text_in_output 'No such device|Unable to detect device type|device lacks SMART capability|SMART support is: Unavailable|Unknown USB bridge|Read Device Identity failed|open device: .* failed' "${file}"; then
    echo "unavailable"
  elif has_text_in_output 'SMART overall-health self-assessment test result: FAILED|FAILING_NOW|SMART Health Status: BAD|SMART.*BAD' "${file}"; then
    echo "failed"
  else
    echo "unknown"
  fi
}

firmware_update_state() {
  local file="$1"
  [ -f "${file}" ] || { echo "unknown"; return 0; }
  if has_text_in_output 'No updates available|No updatable devices|Devices with no available firmware updates' "${file}"; then
    echo "none"
  elif has_text_in_output 'Update|Upgrade|New version|Releases available' "${file}"; then
    echo "available"
  elif has_text_in_output 'Failed to connect|No supported devices|not authorized|daemon|Operation not permitted|Read-only file system' "${file}"; then
    echo "unavailable"
  else
    echo "unknown"
  fi
}

btrfs_profile_from_file() {
  local file="$1"
  local kind="$2"
  awk -v kind="${kind}" '
    $0 ~ "^" kind "," {
      sub("^" kind ",", "", $1)
      sub(":", "", $1)
      print $1
      exit
    }
  ' "${file}" 2>/dev/null
}

btrfs_device_count_from_show_file() {
  local file="$1"
  awk '
    /Total devices/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "devices") {
          print $(i + 1)
          exit
        }
      }
    }
    /^[[:space:]]*devid[[:space:]]+/ { count++ }
    END {
      if (count > 0) {
        print count
      }
    }
  ' "${file}" 2>/dev/null | sed -n '1p'
}

btrfs_balance_state() {
  local file="$1"
  [ -f "${file}" ] || { echo "unknown"; return 0; }
  if has_text_in_output 'No balance found' "${file}"; then
    echo "idle"
  elif has_text_in_output 'running|paused' "${file}"; then
    echo "active"
  elif has_text_in_output 'permission denied|operation not permitted' "${file}"; then
    echo "restricted"
  else
    echo "unknown"
  fi
}

btrfs_restripe_hint() {
  local device_count="$1"
  local data_profile="$2"
  local metadata_profile="$3"
  local balance_state="$4"

  if [ "${device_count:-0}" -le 1 ]; then
    echo "not-applicable"
  elif [ "${balance_state}" = "active" ]; then
    echo "balance-active"
  elif [ "${data_profile}" = "single" ] || [ "${data_profile}" = "raid0" ] || [ "${metadata_profile}" = "single" ]; then
    echo "consider-restripe"
  else
    echo "monitor"
  fi
}

include_device_record() {
  local device_path="$1"
  local device_type="$2"

  case "${device_path}" in
    /dev/loop*|/dev/zram*|/dev/ram*|/dev/sr*)
      return 1
      ;;
  esac

  case "${device_type}" in
    disk|raid)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_target_user

TOP_PATH_TARGETS="${STORAGE_AUDIT_TOP_PATH_TARGETS:-/:${TARGET_HOME}}"
CLEANUP_PATHS="${STORAGE_AUDIT_CLEANUP_PATHS:-${TARGET_HOME}/.cache:${TARGET_HOME}/.local/share/Trash:/var/cache/dnf:/var/cache/PackageKit:/var/cache/akmods:/var/log/journal:/var/lib/systemd/coredump:/var/tmp}"
DEVICE_PATHS="${STORAGE_AUDIT_DEVICE_PATHS:-}"

{
  printf 'file\tstatus\tcommand\n'
} >"${STATUS_FILE}"

log "Writing storage report to ${REPORT_DIR}"

write_cmd_output "timestamp.txt" date --iso-8601=seconds
write_cmd_output "findmnt.txt" findmnt -n -P -o TARGET,SOURCE,FSTYPE,OPTIONS
write_cmd_output "df.txt" df -B1 --output=target,fstype,size,used,avail,pcent
write_cmd_output "lsblk.txt" lsblk -b -d -P -o PATH,SIZE,ROTA,DISC-GRAN,TYPE,TRAN,MODEL,SERIAL,REV
write_cmd_output "journal-disk-usage.txt" journalctl --disk-usage
write_cmd_output "rpm-kernel-core.tsv" rpm -q --qf $'%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\t%{INSTALLSIZE}\n' kernel-core
write_cmd_output_with_timeout "fwupdmgr-devices.txt" "${FWUPD_TIMEOUT}" fwupdmgr get-devices
write_cmd_output_with_timeout "fwupdmgr-updates.txt" "${FWUPD_TIMEOUT}" fwupdmgr get-updates

declare -A MOUNT_SOURCE
declare -A MOUNT_FSTYPE
declare -A MOUNT_OPTIONS
declare -A MOUNT_SIZE
declare -A MOUNT_USED
declare -A MOUNT_AVAIL
declare -A MOUNT_PCT

if [ -f "${COMMANDS_DIR}/findmnt.txt" ]; then
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    target="$(kv_value "${line}" "TARGET")"
    [ -n "${target}" ] || continue
    MOUNT_SOURCE["${target}"]="$(kv_value "${line}" "SOURCE")"
    MOUNT_FSTYPE["${target}"]="$(kv_value "${line}" "FSTYPE")"
    MOUNT_OPTIONS["${target}"]="$(kv_value "${line}" "OPTIONS")"
  done <"${COMMANDS_DIR}/findmnt.txt"
fi

if [ -f "${COMMANDS_DIR}/df.txt" ]; then
  while read -r target fstype size used avail pcent; do
    [ -n "${target}" ] || continue
    MOUNT_FSTYPE["${target}"]="${fstype}"
    MOUNT_SIZE["${target}"]="${size}"
    MOUNT_USED["${target}"]="${used}"
    MOUNT_AVAIL["${target}"]="${avail}"
    MOUNT_PCT["${target}"]="${pcent}"
  done < <(sed '1d' "${COMMANDS_DIR}/df.txt")
fi

mapfile -t mount_targets < <(printf '%s\n' "${!MOUNT_SIZE[@]}" | sort)

declare -A DU_TARGET_SEEN
scan_targets=()

IFS=: read -r -a top_targets <<<"${TOP_PATH_TARGETS}"
for target in "${top_targets[@]}"; do
  [ -n "${target}" ] || continue
  [ -e "${target}" ] || continue
  if [ -z "${DU_TARGET_SEEN["${target}"]:-}" ]; then
    scan_targets+=("${target}")
    DU_TARGET_SEEN["${target}"]=1
  fi
done

if [ "${SCAN_ALL_MOUNTS}" -eq 1 ]; then
  for target in "${mount_targets[@]}"; do
    fstype="${MOUNT_FSTYPE["${target}"]:-unknown}"
    is_real_filesystem "${fstype}" || continue
    if [ -z "${DU_TARGET_SEEN["${target}"]:-}" ]; then
      scan_targets+=("${target}")
      DU_TARGET_SEEN["${target}"]=1
    fi
  done
fi

for target in "${scan_targets[@]}"; do
  write_du_scan "du-$(safe_slug "${target}").txt" "${target}"
done

for target in "${mount_targets[@]}"; do
  fstype="${MOUNT_FSTYPE["${target}"]:-unknown}"
  is_real_filesystem "${fstype}" || continue
  if [ "${fstype}" = "btrfs" ]; then
    write_cmd_output "btrfs-show-$(safe_slug "${target}").txt" btrfs filesystem show --raw "${target}"
    write_cmd_output "btrfs-usage-$(safe_slug "${target}").txt" btrfs filesystem usage -b "${target}"
    write_cmd_output "btrfs-balance-$(safe_slug "${target}").txt" btrfs balance status "${target}"
  fi
done

if [ -n "${DEVICE_PATHS}" ]; then
  IFS=: read -r -a device_paths <<<"${DEVICE_PATHS}"
else
  mapfile -t device_paths < <(
    while IFS= read -r line; do
      device_path="$(kv_value "${line}" "PATH")"
      device_type="$(kv_value "${line}" "TYPE")"
      include_device_record "${device_path}" "${device_type}" || continue
      [ -n "${device_path}" ] && printf '%s\n' "${device_path}"
    done <"${COMMANDS_DIR}/lsblk.txt"
  )
fi

for device_path in "${device_paths[@]}"; do
  [ -n "${device_path}" ] || continue
  write_cmd_output_with_timeout "smartctl-$(safe_slug "${device_path}").txt" 10 smartctl -i -H "${device_path}"
done

MOUNTS_FILE="${TABLES_DIR}/mounts.tsv"
TOP_PATHS_FILE="${TABLES_DIR}/top-paths.tsv"
CLEANUP_FILE="${TABLES_DIR}/cleanup-candidates.tsv"
DEVICES_FILE="${TABLES_DIR}/hardware-devices.tsv"
BTRFS_FILE="${TABLES_DIR}/btrfs-layout.tsv"
FIRMWARE_FILE="${TABLES_DIR}/firmware-status.tsv"

{
  printf 'mount\tfstype\tsource\tsize_bytes\tused_bytes\tavail_bytes\tuse_percent\tpressure\toptions\n'
  for target in "${mount_targets[@]}"; do
    [ -n "${target}" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${target}" \
      "$(sanitize_field "${MOUNT_FSTYPE["${target}"]:-unknown}")" \
      "$(sanitize_field "${MOUNT_SOURCE["${target}"]:-unknown}")" \
      "${MOUNT_SIZE["${target}"]:-0}" \
      "${MOUNT_USED["${target}"]:-0}" \
      "${MOUNT_AVAIL["${target}"]:-0}" \
      "${MOUNT_PCT["${target}"]:-0%}" \
      "$(mount_pressure "${MOUNT_PCT["${target}"]:-0%}")" \
      "$(sanitize_field "${MOUNT_OPTIONS["${target}"]:-}")"
  done
} >"${MOUNTS_FILE}"

{
  printf 'mount\tpath\tsize_bytes\tsize_human\thint\treason\n'
  IFS=: read -r -a top_targets <<<"${TOP_PATH_TARGETS}"
  for target in "${top_targets[@]}"; do
    [ -n "${target}" ] || continue
    du_file="${COMMANDS_DIR}/du-$(safe_slug "${target}").txt"
    [ -f "${du_file}" ] || continue
    row_count=0
    while read -r size path; do
      [ -n "${path}" ] || continue
      [ "${path}" = "${target}" ] && continue
      printf '%s\t%s\t%s\t%s\treview\tlargest top-level path under %s\n' \
        "${target}" \
        "$(sanitize_field "${path}")" \
        "${size}" \
        "$(human_bytes "${size}")" \
        "${target}"
      row_count=$((row_count + 1))
      [ "${row_count}" -ge "${TOP_LIMIT}" ] && break
    done <"${du_file}"
  done
} >"${TOP_PATHS_FILE}"

{
  printf 'hint\tcategory\titem\tsize_bytes\tsize_human\treason\n'
  IFS=: read -r -a cleanup_targets <<<"${CLEANUP_PATHS}"
  for path in "${cleanup_targets[@]}"; do
    [ -n "${path}" ] || continue
    size="$(dir_size_bytes "${path}")"
    [ "${size}" -gt 0 ] || continue
    category="$(cleanup_category "${path}")"
    hint="$(cleanup_hint "${category}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${hint}" \
      "${category}" \
      "$(sanitize_field "${path}")" \
      "${size}" \
      "$(human_bytes "${size}")" \
      "candidate cleanup path"
  done

  if [ -f "${COMMANDS_DIR}/rpm-kernel-core.tsv" ]; then
    kernel_count="$(wc -l <"${COMMANDS_DIR}/rpm-kernel-core.tsv" | tr -d ' ')"
    if [ "${kernel_count}" -gt 2 ]; then
      total_kernel_bytes="$(awk -F'\t' '{sum += $2} END {print sum + 0}' "${COMMANDS_DIR}/rpm-kernel-core.tsv")"
      avg_kernel_bytes="$(( total_kernel_bytes / kernel_count ))"
      removable_kernel_count=$(( kernel_count - 2 ))
      approx_reclaim=$(( avg_kernel_bytes * removable_kernel_count ))
      printf 'medium\tkernel-packages\tkernel-core (older installs)\t%s\t%s\t%s old kernel packages appear removable after manual review\n' \
        "${approx_reclaim}" \
        "$(human_bytes "${approx_reclaim}")" \
        "${removable_kernel_count}"
    fi
  fi
} >"${CLEANUP_FILE}"

{
  printf 'device_path\ttype\ttransport\trota\tdiscard_granularity\tsize_bytes\tsize_human\tmodel\tserial\tfirmware_rev\tsmart_health\n'
  if [ -f "${COMMANDS_DIR}/lsblk.txt" ]; then
    while IFS= read -r line; do
      [ -n "${line}" ] || continue
      device_path="$(kv_value "${line}" "PATH")"
      [ -n "${device_path}" ] || continue
      device_type="$(kv_value "${line}" "TYPE")"
      include_device_record "${device_path}" "${device_type}" || continue
      smart_file="${COMMANDS_DIR}/smartctl-$(safe_slug "${device_path}").txt"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(sanitize_field "${device_path}")" \
        "$(sanitize_field "${device_type}")" \
        "$(sanitize_field "$(kv_value "${line}" "TRAN")")" \
        "$(sanitize_field "$(kv_value "${line}" "ROTA")")" \
        "$(sanitize_field "$(kv_value "${line}" "DISC-GRAN")")" \
        "$(sanitize_field "$(kv_value "${line}" "SIZE")")" \
        "$(human_bytes "$(kv_value "${line}" "SIZE")")" \
        "$(sanitize_field "$(kv_value "${line}" "MODEL")")" \
        "$(sanitize_field "$(kv_value "${line}" "SERIAL")")" \
        "$(sanitize_field "$(kv_value "${line}" "REV")")" \
        "$(smart_health_from_file "${smart_file}")"
    done <"${COMMANDS_DIR}/lsblk.txt"
  fi
} >"${DEVICES_FILE}"

{
  printf 'mount\tdevice_count\tdata_profile\tmetadata_profile\tbalance_state\trestripe_hint\n'
  for target in "${mount_targets[@]}"; do
    [ "${MOUNT_FSTYPE["${target}"]:-}" = "btrfs" ] || continue
    show_file="${COMMANDS_DIR}/btrfs-show-$(safe_slug "${target}").txt"
    usage_file="${COMMANDS_DIR}/btrfs-usage-$(safe_slug "${target}").txt"
    balance_file="${COMMANDS_DIR}/btrfs-balance-$(safe_slug "${target}").txt"
    [ -f "${usage_file}" ] || continue
    device_count="$(btrfs_device_count_from_show_file "${show_file}")"
    data_profile="$(btrfs_profile_from_file "${usage_file}" "Data")"
    metadata_profile="$(btrfs_profile_from_file "${usage_file}" "Metadata")"
    balance_state="$(btrfs_balance_state "${balance_file}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${target}" \
      "${device_count}" \
      "${data_profile:-unknown}" \
      "${metadata_profile:-unknown}" \
      "${balance_state}" \
      "$(btrfs_restripe_hint "${device_count}" "${data_profile:-}" "${metadata_profile:-}" "${balance_state}")"
  done
} >"${BTRFS_FILE}"

firmware_state="$(firmware_update_state "${COMMANDS_DIR}/fwupdmgr-updates.txt")"
firmware_details="$(filtered_output_lines "${COMMANDS_DIR}/fwupdmgr-updates.txt" 10 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
if [ -z "${firmware_details}" ]; then
  firmware_details="no firmware update details collected"
fi
{
  printf 'state\tdetails\n'
  printf '%s\t%s\n' \
    "${firmware_state}" \
    "$(sanitize_field "${firmware_details}")"
} >"${FIRMWARE_FILE}"

cleanup_count=$(( $(wc -l <"${CLEANUP_FILE}") - 1 ))
device_count_total=$(( $(wc -l <"${DEVICES_FILE}") - 1 ))
btrfs_count=$(( $(wc -l <"${BTRFS_FILE}") - 1 ))
mount_count=$(( $(wc -l <"${MOUNTS_FILE}") - 1 ))
status_failures="$(awk -F'\t' 'NR > 1 && $2 != "0" {count++} END {print count + 0}' "${STATUS_FILE}")"
cleanup_total_bytes="$(awk -F'\t' 'NR > 1 {sum += $4} END {print sum + 0}' "${CLEANUP_FILE}")"

{
  echo "Storage and hardware audit created at:"
  echo "  $(date --iso-8601=seconds)"
  echo
  echo "Contains:"
  echo "  - commands/: raw command outputs and command-status.tsv"
  echo "  - tables/mounts.tsv: mount pressure and filesystem metadata"
  echo "  - tables/top-paths.tsv: largest top-level paths under selected targets"
  echo "  - tables/cleanup-candidates.tsv: space that is likely reclaimable after review"
  echo "  - tables/hardware-devices.tsv: block device inventory with firmware revision and SMART health"
  echo "  - tables/btrfs-layout.tsv: Btrfs profile and restripe/balance hints"
  echo "  - tables/firmware-status.tsv: fwupd update availability summary"
  echo "  - storage-summary.md: human-readable overview"
  echo
  echo "Notes:"
  echo "  - SMART and fwupd coverage is better when the script is run with sudo."
  if [ "${SCAN_ALL_MOUNTS}" -eq 1 ]; then
    echo "  - du scans included every real filesystem mount."
  else
    echo "  - du scans were limited to configured top-path targets; use --scan-all-mounts for wider coverage."
  fi
  echo "  - restripe hints are conservative and are only meaningful for multi-device Btrfs filesystems."
  echo "  - no cleanup command is executed; this is a report only."
} >"${REPORT_DIR}/README.txt"

{
  echo "# Storage And Hardware Audit"
  echo
  echo "- Report: ${REPORT_DIR}"
  echo "- Generated: $(date --iso-8601=seconds)"
  echo "- Target user: ${TARGET_USER}"
  echo
  echo "## Overview"
  echo
  echo "- Mounts analyzed: ${mount_count}"
  echo "- Cleanup candidates detected: ${cleanup_count}"
  printf '%s\n' "- Aggregate candidate bytes: $(human_bytes "${cleanup_total_bytes}")"
  echo "- Hardware devices detected: ${device_count_total}"
  echo "- Btrfs layouts inspected: ${btrfs_count}"
  echo "- Firmware update status: ${firmware_state}"
  echo "- Collection commands with non-zero exit status: ${status_failures}"
  echo
  echo "## Space Pressure"
  echo
  if awk -F'\t' 'NR > 1 && ($7 + 0) >= 80 {exit 0} END {exit 1}' "${MOUNTS_FILE}"; then
    printf '%s\n' '```text'
    awk -F'\t' 'NR > 1 && ($7 + 0) >= 80 {printf "%-18s %-8s used=%-12s free=%-12s pressure=%s\n", $1, $2, $5, $6, $8}' "${MOUNTS_FILE}"
    printf '%s\n' '```'
  else
    echo "No analyzed mount is currently above 80% full."
  fi
  echo
  echo "## Cleanup Queue"
  echo
  if [ "${cleanup_count}" -gt 0 ]; then
    printf '%s\n' '```text'
    awk -F'\t' 'NR > 1 {printf "%-8s %-14s %-50s %12s\n", $1, $2, $3, $5}' "${CLEANUP_FILE}" | sort -k4,4hr | sed -n '1,15p'
    printf '%s\n' '```'
  else
    echo "No cleanup candidates were detected from the configured scan paths."
  fi
  echo
  echo "## Btrfs Restripe Review"
  echo
  if [ "${btrfs_count}" -gt 0 ]; then
    printf '%s\n' '```text'
    awk -F'\t' 'NR > 1 {printf "%-12s devices=%-3s data=%-8s metadata=%-8s balance=%-8s hint=%s\n", $1, $2, $3, $4, $5, $6}' "${BTRFS_FILE}"
    printf '%s\n' '```'
  else
    echo "No Btrfs mount was captured for restripe review."
  fi
  echo
  echo "## Hardware Inventory"
  echo
  if [ "${device_count_total}" -gt 0 ]; then
    printf '%s\n' '```text'
    awk -F'\t' 'NR > 1 {printf "%-14s %-8s transport=%-8s fw=%-12s smart=%s\n", $1, $7, $3, $10, $11}' "${DEVICES_FILE}"
    printf '%s\n' '```'
  else
    echo "No block devices were captured."
  fi
  echo
  echo "## Firmware Update Signals"
  echo
  printf '%s\n' '```text'
  filtered_output_lines "${COMMANDS_DIR}/fwupdmgr-updates.txt" 20
  printf '%s\n' '```'
  echo
  echo "## Next Commands"
  echo
  printf '%s\n' "- Inspect cleanup candidates: \`column -t -s \$'\\t' ${CLEANUP_FILE} | less -S\`"
  printf '%s\n' "- Inspect device inventory: \`column -t -s \$'\\t' ${DEVICES_FILE} | less -S\`"
  printf '%s\n' "- Inspect Btrfs layout hints: \`column -t -s \$'\\t' ${BTRFS_FILE} | less -S\`"
  echo "- Run with sudo for fuller SMART and fwupd coverage."
  echo "- Review cleanup items manually before removing anything."
} >"${SUMMARY_FILE}"

ln -sfn "$(basename "${REPORT_DIR}")" "${OUTPUT_BASE}/storage-latest"

if [ "${PATH_ONLY}" -eq 1 ]; then
  printf '%s\n' "${REPORT_DIR}"
else
  log "Storage audit finished."
  printf 'REPORT_DIR=%s\n' "${REPORT_DIR}"
  printf 'SUMMARY=%s\n' "${SUMMARY_FILE}"
fi
