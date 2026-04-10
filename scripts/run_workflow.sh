#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SNAPSHOT_DIR="$("${SCRIPT_DIR}/collect_snapshot.sh" --path-only "$@")"

if [ -z "${SNAPSHOT_DIR}" ] || [ ! -d "${SNAPSHOT_DIR}" ]; then
  echo "Snapshot collection failed; no snapshot directory returned." >&2
  exit 1
fi

echo "Snapshot: ${SNAPSHOT_DIR}"
"${SCRIPT_DIR}/analyze_snapshot.sh" "${SNAPSHOT_DIR}"
if sidecar_path="$("${SCRIPT_DIR}/export_tachometer_signals.sh" --snapshot-dir "${SNAPSHOT_DIR}")"; then
  echo "Tachometer sidecar: ${sidecar_path}"
else
  echo "Warning: tachometer sidecar export failed." >&2
fi
echo "Latest summary: ${SNAPSHOT_DIR}/analysis-summary.md"
