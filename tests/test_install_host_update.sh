#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
if [ "${KEEP_TMP:-0}" != "1" ]; then trap 'rm -rf "${TMP_DIR}"' EXIT; fi
export DESTDIR="${TMP_DIR}/root"
UNITS="${DESTDIR}/etc/systemd/system"

bash "${ROOT_DIR}/scripts/install_host_update.sh" >/dev/null
assert_file_exists "${DESTDIR}/usr/local/lib/fedora-debugg/host_update.py"
assert_file_exists "${DESTDIR}/usr/local/lib/fedora-debugg/detect_dnf_upgrade_blockers.sh"
[ -x "${DESTDIR}/usr/local/lib/fedora-debugg/host_update.py" ] || fail "installed script is not executable"
for unit in host-update host-reboot; do
  assert_file_exists "${UNITS}/fedora-debugg-${unit}.service"
  assert_file_exists "${UNITS}/fedora-debugg-${unit}.timer"
done
# root runs the installed copy, never the user-writable checkout
assert_not_contains "${UNITS}/fedora-debugg-host-update.service" "${ROOT_DIR}"
assert_contains "${UNITS}/fedora-debugg-host-update.service" "ExecStart=/usr/bin/python3 /usr/local/lib/fedora-debugg/host_update.py upgrade --mode auto"
assert_contains "${UNITS}/fedora-debugg-host-update.service" "SuccessExitStatus=2"
assert_contains "${UNITS}/fedora-debugg-host-update.timer" "Persistent=true"
assert_contains "${UNITS}/fedora-debugg-host-reboot.timer" "Persistent=false"
assert_contains "${UNITS}/fedora-debugg-host-reboot.timer" "04:30:00"

# the installed copy works from where it lives (it finds the blockers script beside it)
"${DESTDIR}/usr/local/lib/fedora-debugg/host_update.py" --state-dir "${TMP_DIR}/st" status >/dev/null

bash "${ROOT_DIR}/scripts/install_host_update.sh" --uninstall >/dev/null
assert_file_not_exists "${UNITS}/fedora-debugg-host-update.timer"
assert_file_not_exists "${DESTDIR}/usr/local/lib/fedora-debugg"

echo "install_host_update tests passed"
