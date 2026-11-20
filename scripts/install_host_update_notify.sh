#!/usr/bin/env bash
# Install the user-level host-update alert job (as your user, not root).
#
# Renders config/clockwork/host-update-notify.toml.template with this checkout's path into the
# ignored config/clockwork/host-update-notify.toml and installs it as a systemd user timer through
# Clockwork. Recipients go in an owner-only ~/.config/fedora-debugg/notify.env.
#
# Usage: bash scripts/install_host_update_notify.sh [--render-only]
#   CLOCKWORK_DIR  Clockwork checkout (default: ../clockwork)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${REPO_ROOT}/config/clockwork/host-update-notify.toml.template"
MANIFEST="${REPO_ROOT}/config/clockwork/host-update-notify.toml"
CLOCKWORK_DIR="${CLOCKWORK_DIR:-${REPO_ROOT}/../clockwork}"

sed "s#__REPO_ROOT__#${REPO_ROOT}#g" "${TEMPLATE}" > "${MANIFEST}"
printf 'rendered %s\n' "${MANIFEST}"
[[ "${1:-}" == "--render-only" ]] && exit 0

[[ -d "${CLOCKWORK_DIR}" ]] || { printf 'error: Clockwork not found at %s (set CLOCKWORK_DIR)\n' "${CLOCKWORK_DIR}" >&2; exit 1; }
(cd "${CLOCKWORK_DIR}" && python3 -m clockwork install --manifest "${MANIFEST}" --target systemd-user)
systemctl --user daemon-reload
systemctl --user enable --now fedora-debugg-host-update-notify.timer
printf 'installed. Put recipients in ~/.config/fedora-debugg/notify.env (FEDORA_DEBUGG_NOTIFY_*_TARGET)\n'
