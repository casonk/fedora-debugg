#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LOG_FILE="${ROOT_DIR}/CHATHISTORY.md"
SNAPSHOT="artifacts/latest"
SUMMARY=""
TITLE=""
NEXT=""

usage() {
  cat <<'EOF'
Usage: ./scripts/log_session.sh --summary "<text>" [options]

Append a local (git-ignored) debugging handoff entry to repo-root CHATHISTORY.md.

Options:
  --summary <text>   Required. What changed + current state.
  --snapshot <path>  Snapshot directory path (default: artifacts/latest).
  --title <text>     Optional short title.
  --next <text>      Optional immediate next action.
  --help             Show this help message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --summary)
      [ $# -lt 2 ] && { echo "Missing value for --summary" >&2; exit 1; }
      SUMMARY="$2"
      shift 2
      ;;
    --snapshot)
      [ $# -lt 2 ] && { echo "Missing value for --snapshot" >&2; exit 1; }
      SNAPSHOT="$2"
      shift 2
      ;;
    --title)
      [ $# -lt 2 ] && { echo "Missing value for --title" >&2; exit 1; }
      TITLE="$2"
      shift 2
      ;;
    --next)
      [ $# -lt 2 ] && { echo "Missing value for --next" >&2; exit 1; }
      NEXT="$2"
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

if [ -z "${SUMMARY}" ]; then
  echo "--summary is required" >&2
  usage >&2
  exit 1
fi

if [ -d "${SNAPSHOT}" ]; then
  SNAPSHOT_DIR="$(cd "${SNAPSHOT}" && pwd)"
elif [ -L "${SNAPSHOT}" ]; then
  SNAPSHOT_DIR="$(cd "$(dirname "${SNAPSHOT}")" && pwd)/$(readlink "${SNAPSHOT}")"
else
  SNAPSHOT_DIR="${SNAPSHOT}"
fi

KERNEL="unknown"
GPU_DRIVER="unknown"
if [ -f "${SNAPSHOT_DIR}/commands/uname.txt" ]; then
  KERNEL="$(awk '/^Linux /{print $3; exit}' "${SNAPSHOT_DIR}/commands/uname.txt")"
fi
if [ -f "${SNAPSHOT_DIR}/commands/lspci.txt" ]; then
  GPU_DRIVER="$(awk '
    /VGA compatible controller/ {in_vga=1; next}
    in_vga && /Kernel driver in use:/ {print $NF; exit}
  ' "${SNAPSHOT_DIR}/commands/lspci.txt")"
  [ -z "${GPU_DRIVER}" ] && GPU_DRIVER="unknown"
fi

mkdir -p "$(dirname "${LOG_FILE}")"

if [ ! -f "${LOG_FILE}" ]; then
  cat >"${LOG_FILE}" <<'EOF'
# CHATHISTORY.md

Local-only repo session log for concise handoff and resume context.
This file is gitignored and must not be committed or published.

## How To Use

- Read this file after `AGENTS.md` when resuming work.
- Keep this file concise: objective, latest diagnosis, blockers, and next step.
- `scripts/log_session.sh` appends the incident timeline entries below.

---
EOF
fi

{
  echo
  echo "## $(date --iso-8601=seconds)${TITLE:+ - ${TITLE}}"
  echo "- Snapshot: ${SNAPSHOT_DIR}"
  echo "- Kernel: ${KERNEL}"
  echo "- GPU driver in use: ${GPU_DRIVER}"
  echo "- Summary: ${SUMMARY}"
  if [ -n "${NEXT}" ]; then
    echo "- Next: ${NEXT}"
  fi
} >>"${LOG_FILE}"

echo "Logged session entry in ${LOG_FILE}"
