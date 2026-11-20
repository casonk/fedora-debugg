#!/usr/bin/env bash
# Install the daily host-update and reboot timers (root).
#
#   fedora-debugg-host-update.timer  03:15  dnf upgrade: security fixes daily, everything on Sunday
#   fedora-debugg-host-reboot.timer  04:30  reboot, only if the update left one required and the host is idle
#
# Root code is copied to a root-owned directory and run from there, never from a checkout an ordinary
# user can edit:
#
#   /usr/local/lib/fedora-debugg/host_update.py, detect_dnf_upgrade_blockers.sh
#   /var/lib/fedora-debugg/host-update/state.json   (world-readable; the user-level notifier reads it)
#
# Alerts come from a separate user-level job (config/clockwork/host-update-notify.toml), because
# the messaging credentials belong to your user, not root.
#
# Usage: sudo bash scripts/install_host_update.sh [--uninstall] [--no-start]
#
# Hold a pending reboot (for example around a firmware update, which can change the TPM PCR 7
# state that ignition's auto-unlock is sealed to): `sudo touch /var/lib/fedora-debugg/host-update/hold-reboot`
# and remove the file when it is safe.
#
# Testing hook: DESTDIR=<dir> stages everything under <dir> and skips the root check and systemctl.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTDIR="${DESTDIR:-}"
LIB_DIR="${DESTDIR}/usr/local/lib/fedora-debugg"
DATA_DIR="${DESTDIR}/var/lib/fedora-debugg/host-update"
UNIT_DIR="${DESTDIR}/etc/systemd/system"

UNINSTALL=0
START=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) UNINSTALL=1; shift ;;
    --no-start) START=0; shift ;;
    --help|-h) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
if [[ -z "${DESTDIR}" ]]; then (( EUID == 0 )) || fail "run with sudo"; fi
systemctl_live() { [[ -n "${DESTDIR}" ]] || systemctl "$@"; }

if (( UNINSTALL == 1 )); then
  systemctl_live disable --now fedora-debugg-host-update.timer fedora-debugg-host-reboot.timer 2>/dev/null || true
  rm -f "${UNIT_DIR}"/fedora-debugg-host-update.{service,timer} "${UNIT_DIR}"/fedora-debugg-host-reboot.{service,timer}
  rm -rf "${LIB_DIR}"
  systemctl_live daemon-reload
  printf 'removed the timers and the installed code; state kept at %s\n' "${DATA_DIR}"
  exit 0
fi

command -v dnf >/dev/null 2>&1 || [[ -n "${DESTDIR}" ]] || fail "dnf not found"
python3 -m py_compile "${REPO_ROOT}/scripts/host_update.py"

install -d -m 0755 "${LIB_DIR}" "${DATA_DIR}" "${UNIT_DIR}"
install -m 0755 "${REPO_ROOT}/scripts/host_update.py" "${LIB_DIR}/host_update.py"
install -m 0755 "${REPO_ROOT}/scripts/detect_dnf_upgrade_blockers.sh" "${LIB_DIR}/detect_dnf_upgrade_blockers.sh"

cat > "${UNIT_DIR}/fedora-debugg-host-update.service" <<'UNIT'
[Unit]
Description=fedora-debugg: apply dnf updates (security daily, everything on Sunday)
Documentation=https://github.com/casonk/fedora-debugg
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=FEDORA_DEBUGG_STATE_DIR=/var/lib/fedora-debugg/host-update
ExecStart=/usr/bin/python3 /usr/local/lib/fedora-debugg/host_update.py upgrade --mode auto
# 2 = blocked by a dependency conflict: a result that is alerted, not a unit failure.
SuccessExitStatus=2
TimeoutStartSec=2h
Nice=10
IOSchedulingClass=idle
UNIT

cat > "${UNIT_DIR}/fedora-debugg-host-update.timer" <<'UNIT'
[Unit]
Description=Daily fedora-debugg host update

[Timer]
OnCalendar=*-*-* 03:15:00
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

cat > "${UNIT_DIR}/fedora-debugg-host-reboot.service" <<'UNIT'
[Unit]
Description=fedora-debugg: reboot for updates when required and the host is idle
Documentation=https://github.com/casonk/fedora-debugg

[Service]
Type=oneshot
Environment=FEDORA_DEBUGG_STATE_DIR=/var/lib/fedora-debugg/host-update
ExecStart=/usr/bin/python3 /usr/local/lib/fedora-debugg/host_update.py reboot
UNIT

cat > "${UNIT_DIR}/fedora-debugg-host-reboot.timer" <<'UNIT'
[Unit]
Description=Nightly fedora-debugg reboot window

[Timer]
OnCalendar=*-*-* 04:30:00
# A reboot window that was missed (machine off) is skipped, not replayed at the next boot.
Persistent=false

[Install]
WantedBy=timers.target
UNIT

systemctl_live daemon-reload
if (( START == 1 )); then
  systemctl_live enable --now fedora-debugg-host-update.timer fedora-debugg-host-reboot.timer
fi
printf 'installed: %s\n' "${LIB_DIR}/host_update.py"
printf 'timers:    fedora-debugg-host-update.timer (03:15), fedora-debugg-host-reboot.timer (04:30)\n'
printf 'state:     %s/state.json\n' "${DATA_DIR}"
printf 'alerts:    install config/clockwork/host-update-notify.toml as your user\n'
