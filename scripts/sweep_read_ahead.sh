#!/usr/bin/env bash
# Benchmark one block device at several read-ahead values, then restore it.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEVICE=""
VALUES=""
FILE_SPEC=""
OUT_DIR=""
RUNS=5
RANDOM_PAGES=4000

usage() {
  cat <<'USAGE'
Usage: sudo ./scripts/sweep_read_ahead.sh --device <dm-2|nvme0n1|...> --values "512 1024 2048" \
            --file LABEL=PATH --out-dir <dir> [--runs 5] [--random-pages 4000]

Sets /sys/block/<device>/queue/read_ahead_kb to each value in turn, runs
scripts/bench_cold_read.py as the invoking user (cold cache, sequential and
random-mmap cost), writes <out-dir>/read-ahead-<value>.json, and restores the
original value on exit, even if a run fails. Record the outcome in
docs/tuning-log.md.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="${2:-}"; shift 2 ;;
    --values) VALUES="${2:-}"; shift 2 ;;
    --file) FILE_SPEC="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --runs) RUNS="${2:-}"; shift 2 ;;
    --random-pages) RANDOM_PAGES="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ "${DEVICE}" =~ ^[a-z0-9-]+$ ]] || { echo "Pass --device as a block device name, e.g. dm-2." >&2; exit 1; }
[ -n "${VALUES}" ] && [ -n "${FILE_SPEC}" ] && [ -n "${OUT_DIR}" ] || { usage >&2; exit 1; }
knob="/sys/block/${DEVICE}/queue/read_ahead_kb"
[ -w "${knob}" ] || { echo "Cannot write ${knob}; run with sudo." >&2; exit 1; }
runner="${SUDO_USER:-$(id -un)}"

original="$(cat "${knob}")"
trap 'echo "${original}" > "${knob}"; echo "Restored ${DEVICE} read_ahead_kb=$(cat "${knob}")"' EXIT

install -d -o "${runner}" "${OUT_DIR}"
for kb in ${VALUES}; do
  [[ "${kb}" =~ ^[0-9]+$ ]] || { echo "Skipping non-numeric value: ${kb}" >&2; continue; }
  echo "${kb}" > "${knob}"
  printf '%s read_ahead_kb=%-6s ' "${DEVICE}" "$(cat "${knob}")"
  sudo -u "${runner}" "${SCRIPT_DIR}/bench_cold_read.py" --file "${FILE_SPEC}" --runs "${RUNS}" \
    --random-pages "${RANDOM_PAGES}" --out "${OUT_DIR}/read-ahead-${kb}.json"
done
