#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
if [ "${KEEP_TMP:-0}" != "1" ]; then
  trap 'rm -rf "${TMP_DIR}"' EXIT
fi

HOME_DIR="${TMP_DIR}/home"
MOCK_BIN="${TMP_DIR}/mock-bin"
FIXTURE_ROOT="${TMP_DIR}/fixture"
OUTPUT_DIR="${TMP_DIR}/output"

mkdir -p \
  "${HOME_DIR}/.config/myapp" \
  "${HOME_DIR}/.local/share/signal-cli" \
  "${HOME_DIR}/.cache/myapp" \
  "${HOME_DIR}/.local/share/applications" \
  "${FIXTURE_ROOT}/applications" \
  "${FIXTURE_ROOT}/autostart" \
  "${FIXTURE_ROOT}/systemd/system" \
  "${FIXTURE_ROOT}/enabled/system" \
  "${FIXTURE_ROOT}/snap/applications" \
  "${FIXTURE_ROOT}/bin" \
  "${MOCK_BIN}"

cat >"${HOME_DIR}/.bash_history" <<'EOF'
flatpak run org.example.Signal
EOF

touch "${HOME_DIR}/.config/myapp/settings.json"
touch "${HOME_DIR}/.local/share/signal-cli/config.json"
touch "${HOME_DIR}/.cache/myapp/cache.bin"
touch "${FIXTURE_ROOT}/bin/myapp"

cat >"${FIXTURE_ROOT}/applications/myapp.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=My App
Exec=${FIXTURE_ROOT}/bin/myapp %U
EOF

cat >"${FIXTURE_ROOT}/autostart/myapp.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=My App
Exec=${FIXTURE_ROOT}/bin/myapp %U
EOF

cat >"${FIXTURE_ROOT}/snap/applications/spotify_spotify.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Spotify
Exec=spotify
X-SnapInstanceName=spotify
EOF

cat >"${FIXTURE_ROOT}/systemd/system/mysvc.service" <<'EOF'
[Unit]
Description=My Service
EOF

ln -s "${FIXTURE_ROOT}/systemd/system/mysvc.service" "${FIXTURE_ROOT}/enabled/system/mysvc.service"

cat >"${MOCK_BIN}/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "+%Y%m%d-%H%M%S" ]; then
  printf '20260101-010203\n'
elif [ "${1:-}" = "--iso-8601=seconds" ]; then
  printf '2026-01-01T01:02:03+00:00\n'
else
  /usr/bin/date "$@"
fi
EOF

cat >"${MOCK_BIN}/getent" <<EOF
#!/usr/bin/env bash
printf 'tester:x:1000:1000:Tester User:%s:/bin/bash\n' "${HOME_DIR}"
EOF

cat >"${MOCK_BIN}/dnf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

has_arg() {
  local needle="$1"
  shift
  local arg
  for arg in "$@"; do
    if [ "${arg}" = "${needle}" ]; then
      return 0
    fi
  done
  return 1
}

if [ "${1:-}" != "repoquery" ]; then
  exit 1
fi

if has_arg --installed "$@"; then
  printf 'myapp-0:1.0-1.x86_64\tmyapp\tx86_64\tUser\t1700000000\t1024\ttestrepo\tMy desktop app\n'
  printf 'mysvc-0:2.0-1.x86_64\tmysvc\tx86_64\tGroup\t1700000001\t2048\ttestrepo\tMy service\n'
  printf 'oldlib-0:3.0-1.noarch\toldlib\tnoarch\tDependency\t1700000002\t512\ttestrepo\tUnused library\n'
  exit 0
fi

if has_arg --userinstalled "$@"; then
  printf 'myapp-0:1.0-1.x86_64\nmysvc-0:2.0-1.x86_64\n'
  exit 0
fi

if has_arg --leaves "$@"; then
  printf 'myapp-0:1.0-1.x86_64\noldlib-0:3.0-1.noarch\n'
  exit 0
fi

if has_arg --unneeded "$@"; then
  printf 'oldlib-0:3.0-1.noarch\n'
  exit 0
fi

exit 1
EOF

cat >"${MOCK_BIN}/flatpak" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "list" ] && [ "${2:-}" = "--app" ]; then
  printf 'org.example.Signal\tSignal Desktop\tstable\tflathub\tsystem\n'
  exit 0
fi

if [ "${1:-}" = "list" ] && [ "${2:-}" = "--runtime" ]; then
  printf 'org.example.Platform\tExample Platform\tstable\tflathub\tsystem\n'
  exit 0
fi

if [ "${1:-}" = "ps" ]; then
  printf 'org.example.Signal\t222\n'
  exit 0
fi

exit 1
EOF

cat >"${MOCK_BIN}/snap" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"${MOCK_BIN}/ps" <<EOF
#!/usr/bin/env bash
printf '111 myapp ${FIXTURE_ROOT}/bin/myapp --serve\n'
printf '222 flatpak flatpak run org.example.Signal\n'
EOF

cat >"${MOCK_BIN}/readlink" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-f" ] && [ "\${2:-}" = "/proc/111/exe" ]; then
  printf '%s\n' "${FIXTURE_ROOT}/bin/myapp"
  exit 0
fi
exit 1
EOF

cat >"${MOCK_BIN}/rpm" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [ "\${1:-}" = "-q" ] && [ "\${2:-}" = "--qf" ] && [ "\${4:-}" = "-f" ]; then
  case "\${5:-}" in
    "${FIXTURE_ROOT}/applications/myapp.desktop"|\
    "${FIXTURE_ROOT}/autostart/myapp.desktop"|\
    "${FIXTURE_ROOT}/bin/myapp")
      printf 'myapp-0:1.0-1.x86_64\n'
      ;;
    "${FIXTURE_ROOT}/systemd/system/mysvc.service")
      printf 'mysvc-0:2.0-1.x86_64\n'
      ;;
    *)
      exit 1
      ;;
  esac
  exit 0
fi

exit 1
EOF

cat >"${MOCK_BIN}/timeout" <<'EOF'
#!/usr/bin/env bash
shift
"$@"
EOF

chmod +x "${MOCK_BIN}"/*

export PATH="${MOCK_BIN}:${PATH}"
export USER="tester"
export HOME="${HOME_DIR}"
export DNF_HOME="${TMP_DIR}/dnf-home"
export DNF_STATE_HOME="${TMP_DIR}/dnf-state"
export SOFTWARE_AUDIT_DESKTOP_DIRS="${FIXTURE_ROOT}/applications:${HOME_DIR}/.local/share/applications"
export SOFTWARE_AUDIT_AUTOSTART_DIRS="${FIXTURE_ROOT}/autostart"
export SOFTWARE_AUDIT_SYSTEM_SERVICE_DIRS="${FIXTURE_ROOT}/systemd/system"
export SOFTWARE_AUDIT_USER_SERVICE_DIRS="${TMP_DIR}/empty-user-services"
export SOFTWARE_AUDIT_ENABLED_SERVICE_DIRS="${FIXTURE_ROOT}/enabled/system"
export SOFTWARE_AUDIT_SNAP_DESKTOP_DIRS="${FIXTURE_ROOT}/snap/applications"
export SOFTWARE_AUDIT_CONFIG_DIRS="${HOME_DIR}/.config:${HOME_DIR}/.local/share:${HOME_DIR}/.cache"
export SOFTWARE_AUDIT_HISTORY_FILES="${HOME_DIR}/.bash_history"

REPORT_DIR="$("${ROOT_DIR}/scripts/analyze_installed_software.sh" --output-dir "${OUTPUT_DIR}" --history-lines 10 --path-only)"

assert_file_exists "${REPORT_DIR}/software-summary.md"
assert_file_exists "${REPORT_DIR}/tables/rpm-packages.tsv"
assert_file_exists "${REPORT_DIR}/tables/applications.tsv"
assert_file_exists "${REPORT_DIR}/tables/rpm-removal-review.tsv"

assert_contains "${REPORT_DIR}/software-summary.md" "- RPM packages analyzed: 3"
assert_contains "${REPORT_DIR}/software-summary.md" "- Desktop applications analyzed: 3"
assert_contains "${REPORT_DIR}/tables/rpm-packages.tsv" $'candidate\tdependency\toldlib-0:3.0-1.noarch'
assert_contains "${REPORT_DIR}/tables/rpm-packages.tsv" $'keep\tservice\tmysvc-0:2.0-1.x86_64'
assert_contains "${REPORT_DIR}/tables/rpm-packages.tsv" "mysvc.service"
assert_contains "${REPORT_DIR}/tables/applications.tsv" $'keep\trpm\tMy App'
assert_contains "${REPORT_DIR}/tables/applications.tsv" $'keep\tflatpak\tSignal Desktop'
assert_contains "${REPORT_DIR}/tables/applications.tsv" $'review\tsnap\tSpotify'
