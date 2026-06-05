#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PORTFOLIO_ROOT="$(cd "${ROOT_DIR}/../.." && pwd)"

OUTPUT_BASE="${ROOT_DIR}/artifacts"
PATH_ONLY=0
TARGET_USER=""
TARGET_HOME=""

usage() {
  cat <<'EOF'
Usage: ./scripts/collect_snapshot.sh [--path-only] [--output-dir <dir>]

Collect Fedora crash-debugging evidence into a timestamped snapshot bundle.

Options:
  --path-only          Print only the snapshot path.
  --output-dir <dir>   Output base directory (default: ./artifacts).
  --help               Show this help message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --path-only)
      PATH_ONLY=1
      shift
      ;;
    --output-dir)
      if [ $# -lt 2 ]; then
        echo "Missing value for --output-dir" >&2
        exit 1
      fi
      OUTPUT_BASE="$2"
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

case "$OUTPUT_BASE" in
  /*) ;;
  *) OUTPUT_BASE="${ROOT_DIR}/${OUTPUT_BASE}" ;;
esac

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BUNDLE_DIR="${OUTPUT_BASE}/snapshot-${TIMESTAMP}"
COMMANDS_DIR="${BUNDLE_DIR}/commands"
mkdir -p "${COMMANDS_DIR}"

log() {
  if [ "${PATH_ONLY}" -eq 0 ]; then
    printf '[collect] %s\n' "$*"
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

resolve_target_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    TARGET_USER="${SUDO_USER}"
  elif [ -n "${USER:-}" ]; then
    TARGET_USER="${USER}"
  else
    TARGET_USER="unknown"
  fi

  TARGET_HOME="$(getent passwd "${TARGET_USER}" 2>/dev/null | awk -F: '{print $6}')"
  if [ -z "${TARGET_HOME}" ]; then
    TARGET_HOME="${HOME:-/home/${TARGET_USER}}"
  fi
}

capture_cmd() {
  local file_name="$1"
  shift
  local out_file="${COMMANDS_DIR}/${file_name}"
  local cmd=("$@")

  {
    printf '# Timestamp: %s\n' "$(date --iso-8601=seconds)"
    printf '# Command:'
    printf ' %q' "${cmd[@]}"
    printf '\n\n'

    if ! has_cmd "${cmd[0]}"; then
      printf "SKIPPED: command '%s' not found in PATH\n" "${cmd[0]}"
      printf '# Exit status: 127\n'
      return 0
    fi

    "${cmd[@]}"
    local status=$?
    printf '\n# Exit status: %s\n' "${status}"
    return 0
  } >"${out_file}" 2>&1
}

log "Writing snapshot to ${BUNDLE_DIR}"
resolve_target_user

capture_cmd "timestamp.txt" date --iso-8601=seconds
capture_cmd "uname.txt" uname -a
capture_cmd "os-release.txt" cat /etc/os-release
capture_cmd "uptime.txt" uptime
capture_cmd "who-boot.txt" who -b
capture_cmd "last-reboots.txt" last -x -n 100

capture_cmd "rpm-kernel-packages.txt" rpm -qa "kernel*"
capture_cmd "rpm-installed-packages.txt" bash -lc "rpm -qa | sort"
capture_cmd "flatpak-installed-apps.txt" flatpak list --app --columns=application
capture_cmd "flatpak-installed-runtimes.txt" flatpak list --runtime --columns=application
capture_cmd "snap-installed.txt" snap list
capture_cmd "python-default-packages.txt" python3 -m pip list --format=freeze
capture_cmd "python-virtualenvs.txt" bash -lc "TARGET_HOME='${TARGET_HOME}'; PORTFOLIO_ROOT='${PORTFOLIO_ROOT}'; for root in \"\$TARGET_HOME/.virtualenvs\" \"\$TARGET_HOME/git\" \"\$PORTFOLIO_ROOT\"; do [ -d \"\$root\" ] || continue; find \"\$root\" -maxdepth 6 -type f -name pyvenv.cfg 2>/dev/null; done | sort -u"
capture_cmd "node-global-packages.txt" bash -lc "if command -v npm >/dev/null 2>&1; then npm -g ls --depth=0 --parseable=true 2>/dev/null | tail -n +2; fi"
capture_cmd "node-project-manifests.txt" bash -lc "TARGET_HOME='${TARGET_HOME}'; PORTFOLIO_ROOT='${PORTFOLIO_ROOT}'; for root in \"\$TARGET_HOME/git\" \"\$PORTFOLIO_ROOT\"; do [ -d \"\$root\" ] || continue; find \"\$root\" -maxdepth 6 \\( -path '*/node_modules' -o -path '*/.git' \\) -prune -o -type f -name package.json -print 2>/dev/null; done | sort -u"
capture_cmd "go-cached-modules.txt" bash -lc "if command -v go >/dev/null 2>&1; then cache=\$(go env GOMODCACHE 2>/dev/null || true); if [ -n \"\$cache\" ] && [ -d \"\$cache/cache/download\" ]; then find \"\$cache/cache/download\" -type f -path '*/@v/*.mod' 2>/dev/null | sort -u; fi; fi"
capture_cmd "go-module-roots.txt" bash -lc "TARGET_HOME='${TARGET_HOME}'; PORTFOLIO_ROOT='${PORTFOLIO_ROOT}'; for root in \"\$TARGET_HOME/git\" \"\$PORTFOLIO_ROOT\"; do [ -d \"\$root\" ] || continue; find \"\$root\" -maxdepth 6 \\( -path '*/.git' -o -path '*/node_modules' \\) -prune -o \\( -type f \\( -name go.mod -o -name go.work \\) -print \\) 2>/dev/null; done | sort -u"
capture_cmd "lscpu.txt" lscpu
capture_cmd "free.txt" free -h
capture_cmd "df.txt" df -hT
capture_cmd "lsblk.txt" lsblk -f
capture_cmd "findmnt.txt" findmnt

capture_cmd "lspci.txt" lspci -nnk
capture_cmd "lsusb.txt" lsusb
capture_cmd "lsmod.txt" lsmod

capture_cmd "journal-list-boots.txt" journalctl --list-boots --no-pager
capture_cmd "journal-current-warn.txt" journalctl -b -p warning..emerg --no-pager -n 2500
capture_cmd "journal-prev-warn.txt" journalctl -b -1 -p warning..emerg --no-pager -n 2500
capture_cmd "journal-prev2-warn.txt" journalctl -b -2 -p warning..emerg --no-pager -n 2500
capture_cmd "journal-kernel-current.txt" journalctl -k -b --no-pager -n 2500
capture_cmd "journal-suspend-events.txt" journalctl --no-pager -o short-iso-precise --since=-14days --grep="The system will suspend now|PM: suspend (entry|exit)|System returned from sleep operation|Performing sleep operation|Power key pressed|Suspend key pressed|Lid closed|New session 'c[0-9]+' of user 'gdm-greeter'"

capture_cmd "dmesg.txt" dmesg -T
capture_cmd "systemd-failed-units.txt" systemctl --failed --all --no-pager
capture_cmd "systemd-logind-config.txt" systemd-analyze cat-config systemd/logind.conf
capture_cmd "systemd-sleep-config.txt" systemd-analyze cat-config systemd/sleep.conf
capture_cmd "coredump-list.txt" coredumpctl list --no-pager
capture_cmd "coredump-codium.txt" coredumpctl list codium --no-pager

capture_cmd "session-env.txt" bash -lc "printf 'TARGET_USER=%s\nTARGET_HOME=%s\n' '${TARGET_USER}' '${TARGET_HOME}'; for key in XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP DESKTOP_SESSION WAYLAND_DISPLAY DISPLAY XDG_SESSION_ID XDG_RUNTIME_DIR; do printf '%s=%s\n' \"\$key\" \"\${!key-}\"; done"
capture_cmd "loginctl-sessions.txt" loginctl list-sessions --no-legend
capture_cmd "loginctl-user-status.txt" loginctl user-status "${TARGET_USER}"
capture_cmd "display-session-files.txt" bash -lc "for d in /usr/share/xsessions /usr/share/wayland-sessions; do printf '# %s\n' \"\$d\"; if [ -d \"\$d\" ]; then ls -1 \"\$d\"; else printf 'MISSING: %s\n' \"\$d\"; fi; printf '\n'; done"
capture_cmd "gdm-custom-conf.txt" cat /etc/gdm/custom.conf
capture_cmd "gdm-dconf-profile.txt" cat /usr/share/dconf/profile/gdm
capture_cmd "gdm-power-overrides.txt" bash -lc "for file in /etc/dconf/db/gdm.d/* /etc/dconf/db/gdm.d/locks/*; do [ -f \"\$file\" ] || continue; if grep -Eiq 'sleep-inactive-(ac|battery)-(timeout|type)' \"\$file\"; then printf '# %s\n' \"\$file\"; cat \"\$file\"; printf '\n'; fi; done"
capture_cmd "rpm-display-session-packages.txt" bash -lc "for pkg in gnome-session gnome-session-wayland-session gnome-session-xsession gdm xorg-x11-server-Xorg; do rpm -q \"\$pkg\" 2>&1 || true; done"

capture_cmd "proc-cmdline.txt" cat /proc/cmdline
capture_cmd "proc-meminfo.txt" cat /proc/meminfo

capture_cmd "nvidia-smi.txt" nvidia-smi
capture_cmd "glxinfo-brief.txt" glxinfo -B
capture_cmd "rpm-gpu-packages.txt" bash -lc "rpm -qa | grep -Ei 'nvidia|mesa|vulkan|xorg-x11-drv' | sort || true"

capture_cmd "rpm-codium.txt" rpm -qi codium
capture_cmd "vscodium-argv-json.txt" bash -lc "TARGET_HOME='${TARGET_HOME}'; if [ -f \"\$TARGET_HOME/.config/VSCodium/argv.json\" ]; then cat \"\$TARGET_HOME/.config/VSCodium/argv.json\"; else echo \"MISSING: \$TARGET_HOME/.config/VSCodium/argv.json\"; fi"
capture_cmd "vscodium-settings-json.txt" bash -lc "TARGET_HOME='${TARGET_HOME}'; if [ -f \"\$TARGET_HOME/.config/VSCodium/User/settings.json\" ]; then cat \"\$TARGET_HOME/.config/VSCodium/User/settings.json\"; else echo \"MISSING: \$TARGET_HOME/.config/VSCodium/User/settings.json\"; fi"
capture_cmd "vscodium-extensions.txt" bash -lc "TARGET_HOME='${TARGET_HOME}'; for d in \"\$TARGET_HOME/.vscode-oss/extensions\" \"\$TARGET_HOME/.vscode/extensions\"; do if [ -d \"\$d\" ]; then echo \"# Extensions in \$d\"; ls -1 \"\$d\"; exit 0; fi; done; echo \"MISSING: no extensions directory found under \$TARGET_HOME\""

ln -sfn "$(basename "${BUNDLE_DIR}")" "${OUTPUT_BASE}/latest"

cat >"${BUNDLE_DIR}/README.txt" <<EOF
Crash snapshot bundle created at:
  $(date --iso-8601=seconds)

Contains:
  - commands/: command output used for crash triage
  - analysis-summary.md: generated by analyze_snapshot.sh

Notes:
  - Some commands may fail due to permissions. Their exit status is preserved.
  - Re-run with sudo for fuller journal and kernel visibility.
EOF

if [ "${PATH_ONLY}" -eq 1 ]; then
  printf '%s\n' "${BUNDLE_DIR}"
else
  log "Snapshot collection finished."
  printf 'SNAPSHOT_DIR=%s\n' "${BUNDLE_DIR}"
fi
