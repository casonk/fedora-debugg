#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ALT_ROOT="${TMP_DIR}/root"
OUTPUT_FILE="${TMP_DIR}/output.txt"
RULE="${ALT_ROOT}/etc/udev/rules.d/61-fedora-debugg-io-tuning.rules"

"${ROOT_DIR}/scripts/install_io_tuning.sh" --root "${ALT_ROOT}" >"${OUTPUT_FILE}"
assert_file_exists "${RULE}"
assert_contains "${RULE}" 'KERNEL=="nvme[0-9]*n[0-9]*"'
assert_contains "${RULE}" 'ATTR{queue/scheduler}="none", ATTR{bdi/read_ahead_kb}="512"'
assert_contains "${RULE}" 'ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline", ATTR{bdi/read_ahead_kb}="512"'
assert_contains "${RULE}" 'ENV{DM_UUID}=="CRYPT-*"'
assert_contains "${RULE}" 'ENV{FEDORA_DEBUGG_LUKS_BACKING}="%c"'
assert_contains "${RULE}" 'nvme*) echo nvme;;'
for pair in 'nvme" 2048' '0" 512' '1" 8192'; do
  backing="${pair%%\" *}"
  kb="${pair##* }"
  grep -A1 "ENV{FEDORA_DEBUGG_LUKS_BACKING}==\"${backing}\"" "${RULE}" | grep -q "read_ahead_kb}=\"${kb}\"" \
    || { echo "expected LUKS on ${backing} to get ${kb} KiB" >&2; exit 1; }
done
assert_contains "${RULE}" 'ATTR{queue/scheduler}="bfq", ATTR{bdi/read_ahead_kb}="8192"'
assert_contains "${OUTPUT_FILE}" "Skipped udevadm for alternate root"

"${ROOT_DIR}/scripts/install_io_tuning.sh" --root "${ALT_ROOT}" >"${OUTPUT_FILE}"
assert_contains "${OUTPUT_FILE}" "Already installed:"

# udevadm verify exists from systemd 253; older hosts (some CI images) skip the check.
if command -v udevadm >/dev/null 2>&1 && udevadm verify --help >/dev/null 2>&1; then
  udevadm verify "${RULE}" >"${OUTPUT_FILE}" 2>&1 \
    || { cat "${OUTPUT_FILE}" >&2; echo "udevadm verify rejected the rules" >&2; exit 1; }
fi

"${ROOT_DIR}/scripts/install_io_tuning.sh" --root "${ALT_ROOT}" --uninstall >"${OUTPUT_FILE}"
if [ -e "${RULE}" ]; then
  echo "expected --uninstall to remove the rule" >&2
  exit 1
fi
