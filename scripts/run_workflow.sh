#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SNAPSHOT_DIR="$("${SCRIPT_DIR}/collect_snapshot.sh" --path-only "$@")"

if [ -z "${SNAPSHOT_DIR}" ] || [ ! -d "${SNAPSHOT_DIR}" ]; then
  echo "Snapshot collection failed; no snapshot directory returned." >&2
  exit 1
fi

echo "Snapshot: ${SNAPSHOT_DIR}"
if [ "${FEDORA_DEBUGG_GPU_PCIE_LOAD_PROBE:-0}" = "1" ]; then
  if probe_path="$("${SCRIPT_DIR}/run_gpu_pcie_load_probe.sh" --snapshot-dir "${SNAPSHOT_DIR}")"; then
    echo "GPU PCIe load probe: ${probe_path}"
  else
    echo "Warning: GPU PCIe load probe failed." >&2
  fi
fi
if security_path="$("${SCRIPT_DIR}/analyze_security_posture.sh" --report-dir "${SNAPSHOT_DIR}/security-posture")"; then
  echo "Security posture: ${security_path}"
else
  echo "Warning: security posture inventory failed." >&2
fi
"${SCRIPT_DIR}/analyze_snapshot.sh" "${SNAPSHOT_DIR}"
if sidecar_path="$("${SCRIPT_DIR}/export_tachometer_signals.sh" --snapshot-dir "${SNAPSHOT_DIR}")"; then
  echo "Tachometer sidecar: ${sidecar_path}"
else
  echo "Warning: tachometer sidecar export failed." >&2
fi
if rotation_output="$("${SCRIPT_DIR}/archive_snapshots.sh" rotate 2>&1)"; then
  echo "Snapshot archive rotation:"
  echo "${rotation_output}"
else
  echo "Warning: snapshot archive rotation failed." >&2
  echo "${rotation_output}" >&2
fi
echo "Latest summary: ${SNAPSHOT_DIR}/analysis-summary.md"
