#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ALT_ROOT="${TMP_DIR}/root"
OUTPUT_FILE="${TMP_DIR}/output.txt"
SETTINGS_NAME="99-fedora-debugg-disable-auto-suspend"

"${ROOT_DIR}/scripts/install_gdm_no_auto_suspend.sh" --root "${ALT_ROOT}" >"${OUTPUT_FILE}"

assert_file_exists "${ALT_ROOT}/etc/dconf/db/gdm.d/${SETTINGS_NAME}"
assert_file_exists "${ALT_ROOT}/etc/dconf/db/gdm.d/locks/${SETTINGS_NAME}"
assert_contains "${ALT_ROOT}/etc/dconf/db/gdm.d/${SETTINGS_NAME}" "sleep-inactive-ac-timeout=0"
assert_contains "${ALT_ROOT}/etc/dconf/db/gdm.d/${SETTINGS_NAME}" "sleep-inactive-ac-type='nothing'"
assert_contains "${ALT_ROOT}/etc/dconf/db/gdm.d/locks/${SETTINGS_NAME}" "/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type"
assert_contains "${OUTPUT_FILE}" "Skipped dconf update for alternate root"

"${ROOT_DIR}/scripts/install_gdm_no_auto_suspend.sh" --root "${ALT_ROOT}" >"${OUTPUT_FILE}"
assert_contains "${OUTPUT_FILE}" "Already installed:"
