#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${FEDORA_DEBUGG_ARTIFACTS_DIR:-${ROOT_DIR}/artifacts}"

usage() {
  cat <<'EOF'
Usage: ./scripts/export_tachometer_signals.sh [--snapshot-dir <dir>] [--output <path>]

Export a small Fedora-specific sidecar JSON file for the tachometer dashboard.

Options:
  --snapshot-dir <dir>  Snapshot directory to export (default: artifacts/latest).
  --output <path>       Output JSON path (default: <snapshot-dir>/tachometer-signals.json).
  --help                Show this help message.
EOF
}

SNAPSHOT_DIR=""
OUTPUT_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot-dir)
      [ $# -lt 2 ] && { echo "Missing value for --snapshot-dir" >&2; exit 1; }
      SNAPSHOT_DIR="$2"
      shift 2
      ;;
    --output)
      [ $# -lt 2 ] && { echo "Missing value for --output" >&2; exit 1; }
      OUTPUT_PATH="$2"
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

if [ -z "${SNAPSHOT_DIR}" ]; then
  if [ -L "${ARTIFACTS_DIR}/latest" ]; then
    latest_target="$(readlink "${ARTIFACTS_DIR}/latest")"
    case "${latest_target}" in
      /*) SNAPSHOT_DIR="${latest_target}" ;;
      *) SNAPSHOT_DIR="$(cd "${ARTIFACTS_DIR}" && pwd)/${latest_target}" ;;
    esac
  elif [ -d "${ARTIFACTS_DIR}/latest" ]; then
    SNAPSHOT_DIR="$(cd "${ARTIFACTS_DIR}/latest" && pwd)"
  else
    SNAPSHOT_DIR="$(ls -1dt "${ARTIFACTS_DIR}"/snapshot-* 2>/dev/null | head -n 1 || true)"
  fi
fi

if [ -z "${SNAPSHOT_DIR}" ] || [ ! -d "${SNAPSHOT_DIR}" ]; then
  echo "No snapshot found to export." >&2
  exit 1
fi

COMMANDS_DIR="${SNAPSHOT_DIR}/commands"
SUMMARY_FILE="${SNAPSHOT_DIR}/analysis-summary.md"

if [ ! -d "${COMMANDS_DIR}" ]; then
  echo "Invalid snapshot: missing commands directory: ${COMMANDS_DIR}" >&2
  exit 1
fi

if [ -z "${OUTPUT_PATH}" ]; then
  OUTPUT_PATH="${SNAPSHOT_DIR}/tachometer-signals.json"
fi

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "${value}"
}

payload_lines() {
  local file="$1"
  [ -f "${file}" ] || return 0
  grep -vE '^(# |$|SKIPPED:|MISSING:)' "${file}" 2>/dev/null || true
}

count_payload_lines() {
  local file="$1"
  payload_lines "${file}" | sed '/^$/d' | wc -l | tr -d ' '
}

count_payload_lines_excluding() {
  local file="$1"
  local exclude_regex="${2:-}"
  local lines

  lines="$(payload_lines "${file}")"
  if [ -n "${exclude_regex}" ]; then
    lines="$(printf '%s\n' "${lines}" | grep -Eiv "${exclude_regex}" 2>/dev/null || true)"
  fi
  printf '%s\n' "${lines}" | sed '/^$/d' | wc -l | tr -d ' '
}

count_matches() {
  local regex="$1"
  shift
  local total=0
  local file
  local count

  for file in "$@"; do
    [ -f "${file}" ] || continue
    count="$(payload_lines "${file}" | grep -Eic "${regex}" 2>/dev/null || true)"
    count="${count:-0}"
    total=$((total + count))
  done
  printf '%s\n' "${total}"
}

collect_nvidia_invalid_mmap_bursts() {
  local file

  for file in "$@"; do
    [ -f "${file}" ] || continue

    awk -v prefix="${file}" '
      /NVRM: VM: invalid mmap/ {
        ts = $1 " " $2 " " $3
        if (count > 0 && ts == last_ts) {
          count++
          next
        }
        if (count > 0) {
          printf "%s:%d:%s: NVRM: VM: invalid mmap (burst x%d)\n", prefix, first_line, last_ts, count
        }
        last_ts = ts
        first_line = FNR
        count = 1
        next
      }
      count > 0 {
        printf "%s:%d:%s: NVRM: VM: invalid mmap (burst x%d)\n", prefix, first_line, last_ts, count
        count = 0
        last_ts = ""
      }
      END {
        if (count > 0) {
          printf "%s:%d:%s: NVRM: VM: invalid mmap (burst x%d)\n", prefix, first_line, last_ts, count
        }
      }
    ' "${file}" 2>/dev/null
  done
}

count_nvidia_invalid_mmap_bursts() {
  local bursts

  bursts="$(collect_nvidia_invalid_mmap_bursts "$@")"
  printf '%s\n' "${bursts}" | sed '/^$/d' | wc -l | tr -d ' '
}

count_command_failures() {
  local failures

  failures="$(grep -H '^# Exit status: [1-9]' "${COMMANDS_DIR}"/*.txt 2>/dev/null || true)"
  printf '%s\n' "${failures}" | sed '/^$/d' | wc -l | tr -d ' '
}

extract_findmnt_options() {
  local target="$1"
  local file="${COMMANDS_DIR}/findmnt.txt"
  if [ ! -f "${file}" ]; then
    return 0
  fi
  awk -v target="${target}" '
    {
      mount_target = $1
      sub(/^[^/]+/, "", mount_target)
      if (mount_target == target) {
        print $NF
        exit
      }
    }
  ' "${file}" 2>/dev/null
}

mount_mode_from_options() {
  local options="$1"
  case ",${options}," in
    *,ro,*) printf 'ro\n' ;;
    *,rw,*) printf 'rw\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

light_max() {
  local value="$1"
  local green_max="$2"
  local yellow_max="$3"

  if [ "${value}" -le "${green_max}" ]; then
    printf 'green\n'
  elif [ "${value}" -le "${yellow_max}" ]; then
    printf 'yellow\n'
  else
    printf 'red\n'
  fi
}

worst_light() {
  local worst="green"
  local light
  local priority
  local worst_priority

  for light in "$@"; do
    case "${light}" in
      red) priority=3 ;;
      yellow) priority=2 ;;
      unknown) priority=1 ;;
      *) priority=0 ;;
    esac
    case "${worst}" in
      red) worst_priority=3 ;;
      yellow) worst_priority=2 ;;
      unknown) worst_priority=1 ;;
      *) worst_priority=0 ;;
    esac
    if [ "${priority}" -gt "${worst_priority}" ]; then
      worst="${light}"
    fi
  done

  printf '%s\n' "${worst}"
}


gpu_pcie_link_rows() {
  local file="${COMMANDS_DIR}/gpu-pcie-links.txt"
  [ -f "${file}" ] || return 0

  awk '
    function flush() {
      if (device == "") {
        return
      }
      current_width_num = current_width + 0
      max_width_num = max_width + 0
      degraded = "no"
      if (current_width_num > 0 && max_width_num > 0 && current_width_num < max_width_num) {
        degraded = "yes"
      }
      speed_downshift = "no"
      if (current_speed != "" && max_speed != "" && current_speed != max_speed) {
        speed_downshift = "yes"
      }
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", device, driver, current_width, max_width, current_speed, max_speed, degraded
    }
    /^pci_device=/ { flush(); device = substr($0, 12); driver = ""; current_width = ""; max_width = ""; current_speed = ""; max_speed = ""; next }
    /^driver=/ { driver = substr($0, 8); next }
    /^current_link_width=/ { current_width = substr($0, 20); next }
    /^max_link_width=/ { max_width = substr($0, 16); next }
    /^current_link_speed=/ { current_speed = substr($0, 20); next }
    /^max_link_speed=/ { max_speed = substr($0, 16); next }
    END { flush() }
  ' "${file}"
}

count_gpu_pcie_links() {
  gpu_pcie_link_rows | sed '/^$/d' | wc -l | tr -d ' '
}

count_degraded_gpu_pcie_links() {
  gpu_pcie_link_rows | awk -F '\t' '$7 == "yes" { count++ } END { print count + 0 }'
}

current_warn_file="${COMMANDS_DIR}/journal-current-warn.txt"
prev_warn_file="${COMMANDS_DIR}/journal-prev-warn.txt"
prev2_warn_file="${COMMANDS_DIR}/journal-prev2-warn.txt"
kernel_warn_file="${COMMANDS_DIR}/journal-kernel-current.txt"
coredump_list_file="${COMMANDS_DIR}/coredump-list.txt"
nvidia_smi_file="${COMMANDS_DIR}/nvidia-smi.txt"
rpm_packages_file="${COMMANDS_DIR}/rpm-installed-packages.txt"
flatpak_apps_file="${COMMANDS_DIR}/flatpak-installed-apps.txt"
flatpak_runtimes_file="${COMMANDS_DIR}/flatpak-installed-runtimes.txt"
snap_packages_file="${COMMANDS_DIR}/snap-installed.txt"
python_packages_file="${COMMANDS_DIR}/python-default-packages.txt"
python_virtualenvs_file="${COMMANDS_DIR}/python-virtualenvs.txt"
node_global_packages_file="${COMMANDS_DIR}/node-global-packages.txt"
node_projects_file="${COMMANDS_DIR}/node-project-manifests.txt"
go_cached_modules_file="${COMMANDS_DIR}/go-cached-modules.txt"
go_module_roots_file="${COMMANDS_DIR}/go-module-roots.txt"
security_tools_file="${SNAPSHOT_DIR}/security-posture/tables/security-tools.tsv"
display_files=("${current_warn_file}" "${prev_warn_file}" "${prev2_warn_file}")

journal_warning_count="$(count_payload_lines "${current_warn_file}")"
command_failure_count="$(count_command_failures)"
display_instability_count="$(count_matches 'connection to xwayland lost|the wayland connection broke|invalid sequence for vsync frame info' "${display_files[@]}")"
session_crash_count="$(count_matches 'process [0-9]+ \\(gnome-shell\\) of user [0-9]+ dumped core|org\\.gnome\\.Shell@wayland\\.service: (main process exited|failed with result)|user@[0-9]+\\.service: main process exited, code=dumped|process [0-9]+ \\(gnome-session-i\\) of user [0-9]+ dumped core' "${display_files[@]}")"
current_coredump_marker_count="$(count_matches 'dumped core|systemd-coredump' "${current_warn_file}")"
coredump_history_count="$(count_matches '^([A-Z][a-z]{2}|Mon|Tue|Wed|Thu|Fri|Sat|Sun) ' "${coredump_list_file}")"
codium_coredump_count="$(count_matches '/usr/share/codium/codium' "${coredump_list_file}")"
gnome_shell_coredump_count="$(count_matches '/usr/bin/gnome-shell' "${coredump_list_file}")"
xwayland_coredump_count="$(count_matches '/usr/bin/Xwayland' "${coredump_list_file}")"
invalid_mmap_burst_count="$(count_nvidia_invalid_mmap_bursts "${current_warn_file}")"
nvidia_fault_count="$(count_matches 'nvrm: xid|nvidia-drm.*error|gpu has fallen off|failed to initialize nvml|nvidia-smi has failed|driver/library version mismatch' "${current_warn_file}" "${kernel_warn_file}" "${nvidia_smi_file}")"
nvml_failure_count="$(count_matches 'failed to initialize nvml|nvidia-smi has failed|driver/library version mismatch' "${nvidia_smi_file}")"
gpu_pcie_link_count="$(count_gpu_pcie_links)"
gpu_pcie_degraded_count="$(count_degraded_gpu_pcie_links)"
root_mount_mode="$(mount_mode_from_options "$(extract_findmnt_options "/")")"
home_mount_mode="$(mount_mode_from_options "$(extract_findmnt_options "/home")")"
btrfs_error_counter_count="$(count_matches 'BTRFS info .* errs:' "${kernel_warn_file}")"
storage_fault_count="$(count_matches 'i/o error|blk_update_request|btrfs error|read-only file system|remount-ro|xfs.*error|ext4-fs error|nvme.*error' "${current_warn_file}" "${prev_warn_file}" "${prev2_warn_file}" "${kernel_warn_file}")"
rpm_package_count="$(count_payload_lines "${rpm_packages_file}")"
flatpak_app_count="$(count_payload_lines "${flatpak_apps_file}")"
flatpak_runtime_count="$(count_payload_lines "${flatpak_runtimes_file}")"
snap_app_count="$(count_payload_lines_excluding "${snap_packages_file}" '^Name[[:space:]]+Version[[:space:]]+Rev[[:space:]]+Tracking[[:space:]]+Publisher[[:space:]]+Notes$')"
python_package_count="$(count_payload_lines "${python_packages_file}")"
python_virtualenv_count="$(count_payload_lines "${python_virtualenvs_file}")"
node_global_package_count="$(count_payload_lines "${node_global_packages_file}")"
node_project_count="$(count_payload_lines "${node_projects_file}")"
go_cached_module_count="$(count_payload_lines "${go_cached_modules_file}")"
go_module_root_count="$(count_payload_lines "${go_module_roots_file}")"
security_present_count="0"
security_partial_count="0"
security_gap_count="0"
security_malware_gap="false"
security_rootkit_gap="false"
security_integrity_gap="false"
security_audit_runtime_gap="false"
security_baseline_gap="false"

if [ -f "${security_tools_file}" ]; then
  security_present_count="$(awk -F '\t' 'NR > 1 && $12 == "present" {count++} END {print count + 0}' "${security_tools_file}" 2>/dev/null)"
  security_partial_count="$(awk -F '\t' 'NR > 1 && $12 == "partial" {count++} END {print count + 0}' "${security_tools_file}" 2>/dev/null)"
  security_gap_count="$(awk -F '\t' 'NR > 1 && $12 == "gap" {count++} END {print count + 0}' "${security_tools_file}" 2>/dev/null)"
  if awk -F '\t' 'NR > 1 && $1 == "malware" && $12 == "gap" {found=1} END {exit found ? 0 : 1}' "${security_tools_file}" 2>/dev/null; then
    security_malware_gap="true"
  fi
  if awk -F '\t' 'NR > 1 && $1 == "rootkit" && $12 == "gap" {found=1} END {exit found ? 0 : 1}' "${security_tools_file}" 2>/dev/null; then
    security_rootkit_gap="true"
  fi
  if awk -F '\t' 'NR > 1 && $1 == "integrity" && $12 == "gap" {found=1} END {exit found ? 0 : 1}' "${security_tools_file}" 2>/dev/null; then
    security_integrity_gap="true"
  fi
  if awk -F '\t' 'NR > 1 && ($1 == "audit" || $1 == "runtime") && $12 == "gap" {found=1} END {exit found ? 0 : 1}' "${security_tools_file}" 2>/dev/null; then
    security_audit_runtime_gap="true"
  fi
  if awk -F '\t' 'NR > 1 && $1 == "baseline" && $12 == "gap" {found=1} END {exit found ? 0 : 1}' "${security_tools_file}" 2>/dev/null; then
    security_baseline_gap="true"
  fi
fi

gpu_driver_alert="false"
if [ "${invalid_mmap_burst_count}" -gt 0 ] || [ "${nvidia_fault_count}" -gt 0 ]; then
  gpu_driver_alert="true"
fi
gpu_pcie_alert="false"
if [ "${gpu_pcie_degraded_count}" -gt 0 ]; then
  gpu_pcie_alert="true"
fi

collection_light="$(light_max "${command_failure_count}" 0 2)"
display_light="green"
if [ "${session_crash_count}" -gt 0 ]; then
  display_light="red"
elif [ "${display_instability_count}" -gt 0 ]; then
  display_light="yellow"
fi
coredumps_light="green"
if [ "${current_coredump_marker_count}" -gt 0 ]; then
  coredumps_light="red"
elif [ "${coredump_history_count}" -gt 0 ]; then
  coredumps_light="yellow"
fi
gpu_light="green"
if [ "${invalid_mmap_burst_count}" -gt 0 ] || [ "${nvml_failure_count}" -gt 0 ] || [ "${nvidia_fault_count}" -ge 3 ]; then
  gpu_light="red"
elif [ "${nvidia_fault_count}" -gt 0 ] || [ "${gpu_pcie_degraded_count}" -gt 0 ]; then
  gpu_light="yellow"
fi
storage_light="green"
if [ "${root_mount_mode}" = "ro" ] || [ "${home_mount_mode}" = "ro" ] || [ "${storage_fault_count}" -gt 0 ]; then
  storage_light="red"
elif [ "${btrfs_error_counter_count}" -gt 0 ]; then
  storage_light="yellow"
fi
overall_light="$(worst_light "${collection_light}" "${display_light}" "${coredumps_light}" "${gpu_light}" "${storage_light}")"

collection_summary="clean"
if [ "${command_failure_count}" -gt 0 ]; then
  collection_summary="${command_failure_count} command failures"
fi

display_summary="stable"
if [ "${session_crash_count}" -gt 0 ]; then
  display_summary="${session_crash_count} session crash markers"
elif [ "${display_instability_count}" -gt 0 ]; then
  display_summary="${display_instability_count} instability markers"
fi

coredumps_summary="clear"
if [ "${current_coredump_marker_count}" -gt 0 ]; then
  coredumps_summary="current ${current_coredump_marker_count}, history ${coredump_history_count}"
elif [ "${coredump_history_count}" -gt 0 ]; then
  coredumps_summary="history ${coredump_history_count}"
fi

gpu_summary="clean"
if [ "${invalid_mmap_burst_count}" -gt 0 ]; then
  gpu_summary="${invalid_mmap_burst_count} mmap bursts"
elif [ "${nvml_failure_count}" -gt 0 ]; then
  gpu_summary="${nvml_failure_count} NVML failures"
elif [ "${nvidia_fault_count}" -gt 0 ]; then
  gpu_summary="${nvidia_fault_count} fault markers"
elif [ "${gpu_pcie_degraded_count}" -gt 0 ]; then
  gpu_summary="${gpu_pcie_degraded_count} PCIe width degraded"
fi

storage_summary="clean"
if [ "${root_mount_mode}" = "ro" ] || [ "${home_mount_mode}" = "ro" ]; then
  storage_summary="read-only mount"
elif [ "${storage_fault_count}" -gt 0 ]; then
  storage_summary="${storage_fault_count} active faults"
elif [ "${btrfs_error_counter_count}" -gt 0 ]; then
  storage_summary="btrfs counters"
fi

packages_light="unknown"
packages_summary="not captured"
if [ "${rpm_package_count}" -gt 0 ] || [ "${flatpak_app_count}" -gt 0 ] || [ "${flatpak_runtime_count}" -gt 0 ] || [ "${snap_app_count}" -gt 0 ]; then
  packages_light="green"
  packages_summary="rpm ${rpm_package_count} / flatpak ${flatpak_app_count} / snap ${snap_app_count}"
fi

python_light="unknown"
python_summary="not captured"
if [ "${python_package_count}" -gt 0 ] || [ "${python_virtualenv_count}" -gt 0 ]; then
  python_light="green"
  python_summary="${python_package_count} pkgs / ${python_virtualenv_count} envs"
fi

node_light="unknown"
node_summary="not captured"
if [ "${node_global_package_count}" -gt 0 ] || [ "${node_project_count}" -gt 0 ]; then
  node_light="green"
  node_summary="${node_global_package_count} global / ${node_project_count} proj"
fi

go_light="unknown"
go_summary="not captured"
if [ "${go_cached_module_count}" -gt 0 ] || [ "${go_module_root_count}" -gt 0 ]; then
  go_light="green"
  go_summary="${go_cached_module_count} mods / ${go_module_root_count} roots"
fi

security_light="unknown"
security_summary="not captured"
if [ -f "${security_tools_file}" ]; then
  if [ "${security_gap_count}" -gt 0 ]; then
    security_light="yellow"
  elif [ "${security_partial_count}" -gt 0 ]; then
    security_light="green"
  else
    security_light="green"
  fi
  security_summary="${security_present_count} present / ${security_partial_count} partial / ${security_gap_count} gaps"
fi

overall_light="$(worst_light "${overall_light}" "${security_light}")"

snapshot_epoch="$(stat -c %Y "${SNAPSHOT_DIR}")"
snapshot_iso="$(date --iso-8601=seconds -d "@${snapshot_epoch}")"
generated_at="$(date --iso-8601=seconds)"

mkdir -p "$(dirname "${OUTPUT_PATH}")"
cat >"${OUTPUT_PATH}" <<EOF
{
  "source": "fedora-debugg",
  "schema_version": 3,
  "generated_at": "${generated_at}",
  "snapshot_path": "$(json_escape "${SNAPSHOT_DIR}")",
  "analysis_summary_path": "$(json_escape "${SUMMARY_FILE}")",
  "latest_snapshot_at": "${snapshot_iso}",
  "latest_snapshot_epoch": ${snapshot_epoch},
  "metrics": {
    "journal_warning_count": ${journal_warning_count},
    "command_failure_count": ${command_failure_count},
    "display_instability_count": ${display_instability_count},
    "session_crash_count": ${session_crash_count},
    "current_coredump_marker_count": ${current_coredump_marker_count},
    "coredump_history_count": ${coredump_history_count},
    "codium_coredump_count": ${codium_coredump_count},
    "gnome_shell_coredump_count": ${gnome_shell_coredump_count},
    "xwayland_coredump_count": ${xwayland_coredump_count},
    "invalid_mmap_burst_count": ${invalid_mmap_burst_count},
    "nvidia_fault_count": ${nvidia_fault_count},
    "nvml_failure_count": ${nvml_failure_count},
    "gpu_pcie_link_count": ${gpu_pcie_link_count},
    "gpu_pcie_degraded_count": ${gpu_pcie_degraded_count},
    "root_mount_mode": "$(json_escape "${root_mount_mode}")",
    "home_mount_mode": "$(json_escape "${home_mount_mode}")",
    "btrfs_error_counter_count": ${btrfs_error_counter_count},
    "storage_fault_count": ${storage_fault_count},
    "rpm_package_count": ${rpm_package_count},
    "flatpak_app_count": ${flatpak_app_count},
    "flatpak_runtime_count": ${flatpak_runtime_count},
    "snap_app_count": ${snap_app_count},
    "python_package_count": ${python_package_count},
    "python_virtualenv_count": ${python_virtualenv_count},
    "node_global_package_count": ${node_global_package_count},
    "node_project_count": ${node_project_count},
    "go_cached_module_count": ${go_cached_module_count},
    "go_module_root_count": ${go_module_root_count},
    "security_present_count": ${security_present_count},
    "security_partial_count": ${security_partial_count},
    "security_gap_count": ${security_gap_count},
    "security_malware_gap": ${security_malware_gap},
    "security_rootkit_gap": ${security_rootkit_gap},
    "security_integrity_gap": ${security_integrity_gap},
    "security_audit_runtime_gap": ${security_audit_runtime_gap},
    "security_baseline_gap": ${security_baseline_gap},
    "gpu_driver_alert": ${gpu_driver_alert},
    "gpu_pcie_alert": ${gpu_pcie_alert}
  },
  "lights": {
    "collection": "${collection_light}",
    "display": "${display_light}",
    "coredumps": "${coredumps_light}",
    "gpu": "${gpu_light}",
    "storage": "${storage_light}",
    "packages": "${packages_light}",
    "security": "${security_light}",
    "python": "${python_light}",
    "node": "${node_light}",
    "go": "${go_light}"
  },
  "buckets": {
    "collection": {
      "label": "Collection",
      "light": "${collection_light}",
      "summary": "$(json_escape "${collection_summary}")",
      "counts": {
        "command_failures": ${command_failure_count}
      }
    },
    "display": {
      "label": "Display",
      "light": "${display_light}",
      "summary": "$(json_escape "${display_summary}")",
      "counts": {
        "instability_markers": ${display_instability_count},
        "session_crash_markers": ${session_crash_count}
      }
    },
    "coredumps": {
      "label": "Coredumps",
      "light": "${coredumps_light}",
      "summary": "$(json_escape "${coredumps_summary}")",
      "counts": {
        "current_markers": ${current_coredump_marker_count},
        "history_entries": ${coredump_history_count},
        "gnome_shell_entries": ${gnome_shell_coredump_count},
        "xwayland_entries": ${xwayland_coredump_count},
        "codium_entries": ${codium_coredump_count}
      }
    },
    "gpu": {
      "label": "GPU",
      "light": "${gpu_light}",
      "summary": "$(json_escape "${gpu_summary}")",
      "counts": {
        "fault_markers": ${nvidia_fault_count},
        "invalid_mmap_bursts": ${invalid_mmap_burst_count},
        "nvml_failures": ${nvml_failure_count},
        "pcie_links": ${gpu_pcie_link_count},
        "pcie_degraded": ${gpu_pcie_degraded_count}
      }
    },
    "storage": {
      "label": "Storage",
      "light": "${storage_light}",
      "summary": "$(json_escape "${storage_summary}")",
      "counts": {
        "active_fault_markers": ${storage_fault_count},
        "btrfs_error_counter_markers": ${btrfs_error_counter_count}
      },
      "mount_modes": {
        "root": "$(json_escape "${root_mount_mode}")",
        "home": "$(json_escape "${home_mount_mode}")"
      }
    },
    "packages": {
      "label": "Packages",
      "light": "${packages_light}",
      "summary": "$(json_escape "${packages_summary}")",
      "counts": {
        "rpm_packages": ${rpm_package_count},
        "flatpak_apps": ${flatpak_app_count},
        "flatpak_runtimes": ${flatpak_runtime_count},
        "snap_apps": ${snap_app_count}
      }
    },
    "security": {
      "label": "Security",
      "light": "${security_light}",
      "summary": "$(json_escape "${security_summary}")",
      "counts": {
        "present": ${security_present_count},
        "partial": ${security_partial_count},
        "gaps": ${security_gap_count}
      },
      "gap_flags": {
        "malware": ${security_malware_gap},
        "rootkit": ${security_rootkit_gap},
        "integrity": ${security_integrity_gap},
        "audit_runtime": ${security_audit_runtime_gap},
        "baseline": ${security_baseline_gap}
      }
    },
    "python": {
      "label": "Python",
      "light": "${python_light}",
      "summary": "$(json_escape "${python_summary}")",
      "counts": {
        "packages": ${python_package_count},
        "virtualenvs": ${python_virtualenv_count}
      }
    },
    "node": {
      "label": "Node",
      "light": "${node_light}",
      "summary": "$(json_escape "${node_summary}")",
      "counts": {
        "global_packages": ${node_global_package_count},
        "projects": ${node_project_count}
      }
    },
    "go": {
      "label": "Go",
      "light": "${go_light}",
      "summary": "$(json_escape "${go_summary}")",
      "counts": {
        "cached_modules": ${go_cached_module_count},
        "module_roots": ${go_module_root_count}
      }
    }
  },
  "overall_light": "${overall_light}"
}
EOF

printf '%s\n' "${OUTPUT_PATH}"
