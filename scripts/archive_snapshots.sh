#!/usr/bin/env bash
# Move stale crash snapshots out of the active artifacts set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${FEDORA_DEBUGG_ARTIFACTS_DIR:-${ROOT_DIR}/artifacts}"
ARCHIVE_DIR="${FEDORA_DEBUGG_ARCHIVE_DIR:-${ARTIFACTS_DIR}/archive}"
SNAPSHOT_ARCHIVE_DIR="${ARCHIVE_DIR}/snapshots"
MANIFEST_PATH="${ARCHIVE_DIR}/snapshot-manifest.tsv"
MIN_AGE_DAYS=30
KEEP_RECENT=12
DRY_RUN=0
ARCHIVE_DIR_EXPLICIT=0

usage() {
  cat <<EOF
Usage: archive_snapshots.sh <command> [options]

Commands:
  status                  Show active and archived snapshot counts.
  rotate                  Move eligible stale snapshots into the archive folder.
  restore SNAPSHOT_NAME   Move an archived snapshot back into artifacts/.

Options:
  --artifacts-dir PATH    Override the artifacts directory.
  --archive-dir PATH      Override the archive directory.
  --min-age-days N        Only rotate snapshots at least N days old (default: 30).
  --keep-recent N         Keep the newest N active snapshots unarchived (default: 12).
  --dry-run               Print planned moves without changing files.
  --help                  Show this help.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

is_snapshot_name() {
  case "$1" in
    snapshot-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

snapshot_epoch() {
  local name="$1"
  local stamp="${name#snapshot-}"
  local day="${stamp%-*}"
  local clock="${stamp#*-}"
  date -d "${day:0:4}-${day:4:2}-${day:6:2} ${clock:0:2}:${clock:2:2}:${clock:4:2}" +%s
}

snapshot_age_days() {
  local name="$1"
  local now
  local then
  now="$(date +%s)"
  then="$(snapshot_epoch "${name}")"
  printf '%s\n' "$(( (now - then) / 86400 ))"
}

snapshot_size_bytes() {
  local path="$1"
  du -sb "${path}" 2>/dev/null | awk '{print $1}'
}

active_snapshots() {
  [ -d "${ARTIFACTS_DIR}" ] || return 0
  find "${ARTIFACTS_DIR}" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'snapshot-[0-9]*-[0-9]*' \
    -printf '%f\n' 2>/dev/null \
    | sort
}

archived_snapshots() {
  [ -d "${SNAPSHOT_ARCHIVE_DIR}" ] || return 0
  find "${SNAPSHOT_ARCHIVE_DIR}" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'snapshot-[0-9]*-[0-9]*' \
    -printf '%f\n' 2>/dev/null \
    | sort
}

ensure_manifest() {
  mkdir -p "${SNAPSHOT_ARCHIVE_DIR}"
  if [ ! -f "${MANIFEST_PATH}" ]; then
    printf 'archived_at\tsnapshot\tage_days\tsize_bytes\tsource_path\tarchive_path\n' >"${MANIFEST_PATH}"
  fi
}

status_command() {
  local active_count archived_count
  active_count="$(active_snapshots | wc -l | tr -d ' ')"
  archived_count="$(archived_snapshots | wc -l | tr -d ' ')"
  printf 'artifacts: %s\n' "${ARTIFACTS_DIR}"
  printf 'archive: %s\n' "${SNAPSHOT_ARCHIVE_DIR}"
  printf 'active snapshots: %s\n' "${active_count}"
  printf 'archived snapshots: %s\n' "${archived_count}"
}

rotate_command() {
  [ -d "${ARTIFACTS_DIR}" ] || fail "artifacts directory does not exist: ${ARTIFACTS_DIR}"
  if [ "${DRY_RUN}" != "1" ]; then
    ensure_manifest
  fi

  local total index moved
  total="$(active_snapshots | wc -l | tr -d ' ')"
  index=0
  moved=0

  while IFS= read -r snapshot; do
    [ -n "${snapshot}" ] || continue
    is_snapshot_name "${snapshot}" || continue
    index=$((index + 1))

    if [ $((total - index)) -lt "${KEEP_RECENT}" ]; then
      printf 'keep recent: %s\n' "${snapshot}"
      continue
    fi

    local age_days source_path target_path size_bytes archived_at
    age_days="$(snapshot_age_days "${snapshot}")"
    if [ "${age_days}" -lt "${MIN_AGE_DAYS}" ]; then
      printf 'keep young: %s (%s days)\n' "${snapshot}" "${age_days}"
      continue
    fi

    source_path="${ARTIFACTS_DIR}/${snapshot}"
    target_path="${SNAPSHOT_ARCHIVE_DIR}/${snapshot}"
    if [ -e "${target_path}" ]; then
      fail "archive target already exists: ${target_path}"
    fi
    if [ ! -O "${source_path}" ]; then
      printf 'skip foreign-owned: %s\n' "${snapshot}"
      continue
    fi

    if [ "${DRY_RUN}" = "1" ]; then
      printf 'would archive: %s -> %s\n' "${source_path}" "${target_path}"
      continue
    fi

    size_bytes="$(snapshot_size_bytes "${source_path}")"
    archived_at="$(date --iso-8601=seconds)"
    mv "${source_path}" "${target_path}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${archived_at}" \
      "${snapshot}" \
      "${age_days}" \
      "${size_bytes}" \
      "${source_path}" \
      "${target_path}" \
      >>"${MANIFEST_PATH}"
    printf 'archived: %s\n' "${snapshot}"
    moved=$((moved + 1))
  done < <(active_snapshots)

  printf 'snapshots archived: %s\n' "${moved}"
}

restore_command() {
  local snapshot="${1:-}"
  [ -n "${snapshot}" ] || fail "restore requires a snapshot name"
  is_snapshot_name "${snapshot}" || fail "invalid snapshot name: ${snapshot}"

  local source_path target_path
  source_path="${SNAPSHOT_ARCHIVE_DIR}/${snapshot}"
  target_path="${ARTIFACTS_DIR}/${snapshot}"

  [ -d "${source_path}" ] || fail "archived snapshot not found: ${source_path}"
  [ ! -e "${target_path}" ] || fail "active snapshot already exists: ${target_path}"

  if [ "${DRY_RUN}" = "1" ]; then
    printf 'would restore: %s -> %s\n' "${source_path}" "${target_path}"
    return
  fi

  mkdir -p "${ARTIFACTS_DIR}"
  mv "${source_path}" "${target_path}"
  printf 'restored: %s\n' "${snapshot}"
}

COMMAND="${1:-status}"
if [ "$#" -gt 0 ]; then
  shift
fi

RESTORE_NAME=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifacts-dir)
      ARTIFACTS_DIR="$2"
      if [ "${ARCHIVE_DIR_EXPLICIT}" = "0" ]; then
        ARCHIVE_DIR="${ARTIFACTS_DIR}/archive"
      fi
      SNAPSHOT_ARCHIVE_DIR="${ARCHIVE_DIR}/snapshots"
      MANIFEST_PATH="${ARCHIVE_DIR}/snapshot-manifest.tsv"
      shift 2
      ;;
    --archive-dir)
      ARCHIVE_DIR="$2"
      ARCHIVE_DIR_EXPLICIT=1
      SNAPSHOT_ARCHIVE_DIR="${ARCHIVE_DIR}/snapshots"
      MANIFEST_PATH="${ARCHIVE_DIR}/snapshot-manifest.tsv"
      shift 2
      ;;
    --min-age-days)
      MIN_AGE_DAYS="$2"
      shift 2
      ;;
    --keep-recent)
      KEEP_RECENT="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      if [ "${COMMAND}" = "restore" ] && [ -z "${RESTORE_NAME}" ]; then
        RESTORE_NAME="$1"
        shift
      else
        fail "unknown argument: $1"
      fi
      ;;
  esac
done

case "${COMMAND}" in
  status)
    status_command
    ;;
  rotate)
    rotate_command
    ;;
  restore)
    restore_command "${RESTORE_NAME}"
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    fail "unknown command: ${COMMAND}"
    ;;
esac
