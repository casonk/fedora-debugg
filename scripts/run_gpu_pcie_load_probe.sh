#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${FEDORA_DEBUGG_ARTIFACTS_DIR:-${ROOT_DIR}/artifacts}"
SYSFS_DEVICES_DIR="${FEDORA_DEBUGG_GPU_PCIE_SYSFS_ROOT:-/sys/bus/pci/devices}"
SNAPSHOT_DIR=""
OUTPUT_PATH=""
DURATION="${FEDORA_DEBUGG_GPU_PCIE_PROBE_DURATION:-15}"
INTERVAL="${FEDORA_DEBUGG_GPU_PCIE_PROBE_INTERVAL:-1}"
WORKLOAD_CMD="${FEDORA_DEBUGG_GPU_PCIE_WORKLOAD:-}"
WORKLOAD_LABEL="custom"

usage() {
  cat <<'EOF'
Usage: run_gpu_pcie_load_probe.sh [--snapshot-dir DIR] [--output PATH] [--duration SECONDS] [--interval SECONDS]

Runs a short GPU workload when one is available, samples GPU PCIe link state
before and during the workload, and writes a parseable report.

Environment overrides:
  FEDORA_DEBUGG_ARTIFACTS_DIR
  FEDORA_DEBUGG_GPU_PCIE_PROBE_DURATION
  FEDORA_DEBUGG_GPU_PCIE_PROBE_INTERVAL
  FEDORA_DEBUGG_GPU_PCIE_WORKLOAD
  FEDORA_DEBUGG_GPU_PCIE_SYSFS_ROOT
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot-dir)
      SNAPSHOT_DIR="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="${2:-}"
      shift 2
      ;;
    --duration)
      DURATION="${2:-}"
      shift 2
      ;;
    --interval)
      INTERVAL="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "${DURATION}" in
  ''|*[!0-9]*) echo "Duration must be a positive integer." >&2; exit 2 ;;
esac
case "${INTERVAL}" in
  ''|*[!0-9]*) echo "Interval must be a positive integer." >&2; exit 2 ;;
esac
if [ "${DURATION}" -lt 1 ] || [ "${INTERVAL}" -lt 1 ]; then
  echo "Duration and interval must be positive integers." >&2
  exit 2
fi

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
  echo "No snapshot directory found. Run scripts/run_workflow.sh first or pass --snapshot-dir." >&2
  exit 1
fi

COMMANDS_DIR="${SNAPSHOT_DIR}/commands"
mkdir -p "${COMMANDS_DIR}"
if [ -z "${OUTPUT_PATH}" ]; then
  OUTPUT_PATH="${COMMANDS_DIR}/gpu-pcie-load-probe.txt"
fi
WORKLOAD_LOG="${OUTPUT_PATH}.workload.log"
SAMPLES_FILE="$(mktemp)"
trap 'rm -f "${SAMPLES_FILE}"' EXIT

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

choose_workload() {
  if [ -n "${WORKLOAD_CMD}" ]; then
    printf '%s\t%s\n' "${WORKLOAD_LABEL}" "${WORKLOAD_CMD}"
    return 0
  fi

  if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    if has_cmd glmark2; then
      printf '%s\t%s\n' "glmark2" "glmark2 --run-forever"
      return 0
    fi
    if has_cmd vkmark; then
      printf '%s\t%s\n' "vkmark" "vkmark"
      return 0
    fi
    if has_cmd glxgears; then
      printf '%s\t%s\n' "glxgears" "vblank_mode=0 __GL_SYNC_TO_VBLANK=0 glxgears"
      return 0
    fi
    if has_cmd vkcube; then
      printf '%s\t%s\n' "vkcube" "vkcube"
      return 0
    fi
  fi

  return 1
}

sample_links() {
  local phase="$1"
  local sample_index="$2"
  local timestamp
  timestamp="$(date -Is)"

  for dev in "${SYSFS_DEVICES_DIR}"/*; do
    [ -f "${dev}/class" ] || continue
    class="$(cat "${dev}/class" 2>/dev/null || true)"
    vendor="$(cat "${dev}/vendor" 2>/dev/null || true)"
    case "${class}:${vendor}" in
      0x03*:0x10de|0x03*:0x1002|0x03*:0x8086) ;;
      *) continue ;;
    esac

    printf 'sample_phase=%s\n' "${phase}"
    printf 'sample_index=%s\n' "${sample_index}"
    printf 'sample_timestamp=%s\n' "${timestamp}"
    printf 'pci_device=%s\n' "${dev##*/}"
    for field in vendor device subsystem_vendor subsystem_device class current_link_speed current_link_width max_link_speed max_link_width; do
      value="$(cat "${dev}/${field}" 2>/dev/null || true)"
      printf '%s=%s\n' "${field}" "${value}"
    done
    driver="$(readlink "${dev}/driver/module" 2>/dev/null | sed 's#.*/##' || true)"
    printf 'driver=%s\n\n' "${driver}"
  done
}

write_summary() {
  awk '
    function flush() {
      if (pci == "") {
        return
      }
      link_seen[pci] = 1
      width_num = width + 0
      max_width_num = max_width + 0
      speed_num = speed + 0
      max_speed_num = max_speed + 0
      if (phase == "before") {
        before_seen[pci] = 1
        if (width_num > before_width[pci]) before_width[pci] = width_num
        if (speed_num > before_speed[pci]) before_speed[pci] = speed_num
      }
      if (phase == "during") {
        during_seen[pci] = 1
        if (width_num > during_width[pci]) during_width[pci] = width_num
        if (speed_num > during_speed[pci]) during_speed[pci] = speed_num
      }
      if (width_num > observed_width[pci]) observed_width[pci] = width_num
      if (max_width_num > cap_width[pci]) cap_width[pci] = max_width_num
      if (speed_num > observed_speed[pci]) {
        observed_speed[pci] = speed_num
        observed_speed_label[pci] = speed
      }
      if (max_speed_num > cap_speed[pci]) {
        cap_speed[pci] = max_speed_num
        cap_speed_label[pci] = max_speed
      }
      pci = ""; phase = ""; width = ""; max_width = ""; speed = ""; max_speed = ""
    }
    /^sample_phase=/ { flush(); phase = substr($0, 14); next }
    /^pci_device=/ { pci = substr($0, 12); next }
    /^current_link_width=/ { width = substr($0, 20); next }
    /^max_link_width=/ { max_width = substr($0, 16); next }
    /^current_link_speed=/ { speed = substr($0, 20); next }
    /^max_link_speed=/ { max_speed = substr($0, 16); next }
    END {
      flush()
      link_count = 0
      degraded_before = 0
      degraded_during = 0
      speed_increased = "no"
      max_observed_width = 0
      max_cap_width = 0
      max_observed_speed = 0
      max_observed_speed_label = "unknown"
      max_cap_speed = 0
      max_cap_speed_label = "unknown"
      for (dev in link_seen) {
        link_count++
        if (cap_width[dev] > 0 && before_width[dev] > 0 && before_width[dev] < cap_width[dev]) degraded_before++
        if (cap_width[dev] > 0 && during_width[dev] > 0 && during_width[dev] < cap_width[dev]) degraded_during++
        if (during_speed[dev] > before_speed[dev]) speed_increased = "yes"
        if (observed_width[dev] > max_observed_width) max_observed_width = observed_width[dev]
        if (cap_width[dev] > max_cap_width) max_cap_width = cap_width[dev]
        if (observed_speed[dev] > max_observed_speed) {
          max_observed_speed = observed_speed[dev]
          max_observed_speed_label = observed_speed_label[dev]
        }
        if (cap_speed[dev] > max_cap_speed) {
          max_cap_speed = cap_speed[dev]
          max_cap_speed_label = cap_speed_label[dev]
        }
      }
      print "result_pcie_link_count=" link_count
      print "result_width_degraded_before=" degraded_before
      print "result_width_degraded_during=" degraded_during
      print "result_speed_increased_under_load=" speed_increased
      print "result_max_observed_width=" max_observed_width
      print "result_max_cap_width=" max_cap_width
      print "result_max_observed_speed=" max_observed_speed_label
      print "result_max_cap_speed=" max_cap_speed_label
    }
  ' "${SAMPLES_FILE}"
}

workload_status="skipped"
workload_exit_status=""
workload_label="none"
workload_command=""

sample_links before 0 >>"${SAMPLES_FILE}"

if workload_line="$(choose_workload)"; then
  workload_label="${workload_line%%$'\t'*}"
  workload_command="${workload_line#*$'\t'}"
  : >"${WORKLOAD_LOG}"
  set +e
  timeout "${DURATION}" bash -lc "${workload_command}" >"${WORKLOAD_LOG}" 2>&1 &
  workload_pid=$!
  set -e
  sleep 1
  sample_index=1
  while kill -0 "${workload_pid}" >/dev/null 2>&1; do
    sample_links during "${sample_index}" >>"${SAMPLES_FILE}"
    sample_index=$((sample_index + 1))
    if [ "${sample_index}" -gt "${DURATION}" ]; then
      break
    fi
    sleep "${INTERVAL}"
  done
  set +e
  wait "${workload_pid}"
  workload_exit_status=$?
  set -e
  if [ "${workload_exit_status}" -eq 124 ]; then
    workload_status="timeout"
  elif [ "${workload_exit_status}" -eq 0 ]; then
    workload_status="completed"
  else
    workload_status="failed"
  fi
else
  sample_links during 1 >>"${SAMPLES_FILE}"
fi

sample_links after 0 >>"${SAMPLES_FILE}"

{
  printf '# GPU PCIe Load Probe\n'
  printf 'snapshot_dir=%s\n' "${SNAPSHOT_DIR}"
  printf 'probe_timestamp=%s\n' "$(date -Is)"
  printf 'duration_seconds=%s\n' "${DURATION}"
  printf 'interval_seconds=%s\n' "${INTERVAL}"
  printf 'workload_label=%s\n' "${workload_label}"
  printf 'workload_command=%s\n' "${workload_command}"
  printf 'workload_status=%s\n' "${workload_status}"
  printf 'workload_exit_status=%s\n' "${workload_exit_status}"
  printf '\n'
  write_summary
  printf '\n## samples\n\n'
  cat "${SAMPLES_FILE}"
  if [ -f "${WORKLOAD_LOG}" ]; then
    printf '\n## workload_log\n\n'
    sed -n '1,80p' "${WORKLOAD_LOG}"
  fi
} >"${OUTPUT_PATH}"

printf '%s\n' "${OUTPUT_PATH}"
