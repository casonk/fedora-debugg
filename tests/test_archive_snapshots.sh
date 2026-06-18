#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ARTIFACTS_DIR="${TMP_DIR}/artifacts"
ARCHIVE_DIR="${ARTIFACTS_DIR}/archive"
mkdir -p "${ARTIFACTS_DIR}"

for snapshot in \
  snapshot-20260101-010101 \
  snapshot-20260102-010101 \
  snapshot-20260103-010101 \
  snapshot-20260610-010101; do
  mkdir -p "${ARTIFACTS_DIR}/${snapshot}/commands"
  printf '# %s\n' "${snapshot}" >"${ARTIFACTS_DIR}/${snapshot}/analysis-summary.md"
  printf 'journal\n' >"${ARTIFACTS_DIR}/${snapshot}/commands/journal.txt"
done

dry_run_output="$(
  "${ROOT_DIR}/scripts/archive_snapshots.sh" rotate \
    --artifacts-dir "${ARTIFACTS_DIR}" \
    --archive-dir "${ARCHIVE_DIR}" \
    --min-age-days 30 \
    --keep-recent 1 \
    --dry-run
)"
printf '%s\n' "${dry_run_output}" >"${TMP_DIR}/dry-run.txt"
assert_contains "${TMP_DIR}/dry-run.txt" "would archive:"
assert_file_exists "${ARTIFACTS_DIR}/snapshot-20260101-010101"

rotate_output="$(
  "${ROOT_DIR}/scripts/archive_snapshots.sh" rotate \
    --artifacts-dir "${ARTIFACTS_DIR}" \
    --archive-dir "${ARCHIVE_DIR}" \
    --min-age-days 30 \
    --keep-recent 1
)"
printf '%s\n' "${rotate_output}" >"${TMP_DIR}/rotate.txt"

assert_contains "${TMP_DIR}/rotate.txt" "archived: snapshot-20260101-010101"
assert_contains "${TMP_DIR}/rotate.txt" "archived: snapshot-20260102-010101"
assert_contains "${TMP_DIR}/rotate.txt" "archived: snapshot-20260103-010101"
assert_contains "${TMP_DIR}/rotate.txt" "keep recent: snapshot-20260610-010101"
assert_contains "${TMP_DIR}/rotate.txt" "snapshots archived: 3"

assert_file_not_exists "${ARTIFACTS_DIR}/snapshot-20260101-010101"
assert_file_exists "${ARCHIVE_DIR}/snapshots/snapshot-20260101-010101/analysis-summary.md"
assert_file_exists "${ARCHIVE_DIR}/snapshot-manifest.tsv"
assert_contains "${ARCHIVE_DIR}/snapshot-manifest.tsv" $'snapshot-20260101-010101'

status_output="$(
  "${ROOT_DIR}/scripts/archive_snapshots.sh" status \
    --artifacts-dir "${ARTIFACTS_DIR}" \
    --archive-dir "${ARCHIVE_DIR}"
)"
printf '%s\n' "${status_output}" >"${TMP_DIR}/status.txt"
assert_contains "${TMP_DIR}/status.txt" "active snapshots: 1"
assert_contains "${TMP_DIR}/status.txt" "archived snapshots: 3"

restore_output="$(
  "${ROOT_DIR}/scripts/archive_snapshots.sh" restore snapshot-20260101-010101 \
    --artifacts-dir "${ARTIFACTS_DIR}" \
    --archive-dir "${ARCHIVE_DIR}"
)"
printf '%s\n' "${restore_output}" >"${TMP_DIR}/restore.txt"
assert_contains "${TMP_DIR}/restore.txt" "restored: snapshot-20260101-010101"
assert_file_exists "${ARTIFACTS_DIR}/snapshot-20260101-010101/analysis-summary.md"
assert_file_not_exists "${ARCHIVE_DIR}/snapshots/snapshot-20260101-010101"
