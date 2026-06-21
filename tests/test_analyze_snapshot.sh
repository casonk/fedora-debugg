#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SNAPSHOT_DIR="${TMP_DIR}/snapshot-fixture"
COMMANDS_DIR="${SNAPSHOT_DIR}/commands"
mkdir -p "${COMMANDS_DIR}"
mkdir -p "${SNAPSHOT_DIR}/security-posture/tables"

cat >"${COMMANDS_DIR}/last-reboots.txt" <<'EOF'
reboot   system boot  6.9.0-0.fc43    Fri Mar 22 13:30   still running
reboot   system boot  6.9.0-0.fc43    Fri Mar 22 12:10 - crash
EOF

cat >"${COMMANDS_DIR}/journal-list-boots.txt" <<'EOF'
-2 11111111111111111111111111111111 Wed 2026-03-20 10:00:00 EDT Wed 2026-03-20 10:30:00 EDT
-1 22222222222222222222222222222222 Thu 2026-03-21 12:00:00 EDT Thu 2026-03-21 12:20:00 EDT
 0 33333333333333333333333333333333 Fri 2026-03-22 13:30:00 EDT Fri 2026-03-22 13:45:00 EDT
EOF

cat >"${COMMANDS_DIR}/journal-current-warn.txt" <<'EOF'
Mar 22 13:31:00 host kernel: NVRM: VM: invalid mmap
Mar 22 13:31:00 host kernel: NVRM: VM: invalid mmap
Mar 22 13:31:10 host codium[111]: trap int3 ip:1234 sp:5678 error:0 in codium
Mar 22 13:31:12 host firefox[333]: the Wayland connection broke
Mar 22 13:31:13 host gnome-shell[222]: Connection to xwayland lost
EOF

cat >"${COMMANDS_DIR}/journal-prev-warn.txt" <<'EOF'
Mar 21 12:10:00 host systemd-coredump[99]: Process 222 (gnome-shell) of user 1000 dumped core.
EOF

cat >"${COMMANDS_DIR}/journal-prev2-warn.txt" <<'EOF'
Mar 20 10:10:00 host kernel: corrupted page table
EOF

cat >"${COMMANDS_DIR}/journal-kernel-current.txt" <<'EOF'
Mar 22 13:31:00 host kernel: BTRFS info (device nvme0n1p2): errs: wr 0, rd 0, flush 0, corrupt 8, gen 0
Mar 22 13:31:00 host kernel: NVRM: VM: invalid mmap
EOF

cat >"${COMMANDS_DIR}/journal-suspend-events.txt" <<'EOF'
-- Boot aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --
2026-03-20T10:00:00.000000-04:00 host systemd-logind[100]: New session 'c1' of user 'gdm-greeter' with class 'greeter' and type 'wayland'.
2026-03-20T10:15:01.000000-04:00 host systemd-logind[100]: The system will suspend now!
2026-03-20T11:00:00.000000-04:00 host kernel: PM: suspend exit
2026-03-20T11:15:00.000000-04:00 host systemd-logind[100]: The system will suspend now!
-- Boot bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --
2026-03-21T12:00:00.000000-04:00 host systemd-logind[200]: New session 'c1' of user 'gdm-greeter' with class 'greeter' and type 'wayland'.
2026-03-21T12:05:00.000000-04:00 host systemd-logind[200]: Power key pressed short.
2026-03-21T12:05:00.100000-04:00 host systemd-logind[200]: The system will suspend now!
EOF

cat >"${COMMANDS_DIR}/gdm-dconf-profile.txt" <<'EOF'
user-db:user
system-db:gdm
EOF

cat >"${COMMANDS_DIR}/gdm-power-overrides.txt" <<'EOF'
# No GDM power overrides captured
EOF

cat >"${COMMANDS_DIR}/findmnt.txt" <<'EOF'
/ /dev/nvme0n1p2 btrfs rw,relatime,compress=zstd:1
/home /dev/nvme0n1p3 btrfs rw,relatime,compress=zstd:1
EOF

cat >"${COMMANDS_DIR}/display-session-files.txt" <<'EOF'
# /usr/share/xsessions
gnome-xorg.desktop

# /usr/share/wayland-sessions
gnome.desktop
EOF

cat >"${COMMANDS_DIR}/rpm-display-session-packages.txt" <<'EOF'
gnome-session-49.0-1.fc43.x86_64
gnome-session-wayland-session-49.0-1.fc43.x86_64
gnome-session-xsession-49.0-1.fc43.x86_64
gdm-46.2-1.fc43.x86_64
xorg-x11-server-Xorg-21.1.21-1.fc43.x86_64
EOF

cat >"${COMMANDS_DIR}/gdm-custom-conf.txt" <<'EOF'
[daemon]
# WaylandEnable=false
EOF

cat >"${COMMANDS_DIR}/coredump-list.txt" <<'EOF'
TIME                           PID  UID  GID SIG COREFILE EXE
Fri 2026-03-22 13:31:10 EDT    111 1000 1000  5 present  /usr/share/codium/codium
Fri 2026-03-22 13:31:12 EDT    222 1000 1000 11 present  /usr/bin/gnome-shell
Fri 2026-03-22 13:31:13 EDT    333 1000 1000 11 present  /usr/bin/Xwayland
EOF

cat >"${COMMANDS_DIR}/coredump-codium.txt" <<'EOF'
Fri 2026-03-22 13:31:10 EDT 111 1000 1000 5 present /usr/share/codium/codium
EOF

cat >"${COMMANDS_DIR}/dmi-id.txt" <<'EOF'
bios_vendor=American Megatrends Inc.
bios_version=3006
bios_date=10/12/2021
board_vendor=ASUSTeK COMPUTER INC.
board_name=PRIME Z390-P
EOF

cat >"${COMMANDS_DIR}/lspci-tree.txt" <<'EOF'
-[0000:00]-+-01.0-[01]--
           +-1b.4-[03]--+-00.0  NVIDIA Corporation GA102 [GeForce RTX 3090]
EOF

cat >"${COMMANDS_DIR}/nvidia-smi.txt" <<'EOF'
NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.
EOF

cat >"${COMMANDS_DIR}/gpu-pcie-links.txt" <<'EOF'
pci_device=0000:03:00.0
vendor=0x10de
device=0x2204
subsystem_vendor=0x3842
subsystem_device=0x3982
class=0x030000
current_link_speed=2.5 GT/s PCIe
current_link_width=4
max_link_speed=16.0 GT/s PCIe
max_link_width=16
driver=nvidia

EOF

cat >"${COMMANDS_DIR}/gpu-pcie-load-probe.txt" <<'EOF'
# GPU PCIe Load Probe
snapshot_dir=/tmp/snapshot-fixture
probe_timestamp=2026-06-17T08:00:00-04:00
duration_seconds=2
interval_seconds=1
workload_label=glxgears
workload_command=vblank_mode=0 __GL_SYNC_TO_VBLANK=0 glxgears
workload_status=timeout
workload_exit_status=124

result_pcie_link_count=1
result_width_degraded_before=1
result_width_degraded_during=1
result_speed_increased_under_load=yes
result_max_observed_width=4
result_max_cap_width=16
result_max_observed_speed=16.0 GT/s PCIe
result_max_cap_speed=16.0 GT/s PCIe

## samples
EOF

cat >"${COMMANDS_DIR}/session-env.txt" <<'EOF'
XDG_SESSION_TYPE=wayland
WAYLAND_DISPLAY=wayland-0
DISPLAY=:0
EOF

cat >"${COMMANDS_DIR}/vscodium-argv-json.txt" <<'EOF'
{
  "disable-hardware-acceleration": true
}
EOF

cat >"${COMMANDS_DIR}/dmesg.txt" <<'EOF'
[    1.000000] traps: codium[111] trap int3 ip:1234 sp:5678 error:0 in codium
EOF

cat >"${COMMANDS_DIR}/rpm-installed-packages.txt" <<'EOF'
kernel-core-1
git-2
python3-3
EOF

cat >"${COMMANDS_DIR}/flatpak-installed-apps.txt" <<'EOF'
org.example.Signal
EOF

cat >"${COMMANDS_DIR}/flatpak-installed-runtimes.txt" <<'EOF'
org.freedesktop.Platform
org.gnome.Platform
EOF

cat >"${COMMANDS_DIR}/snap-installed.txt" <<'EOF'
Name    Version    Rev   Tracking       Publisher   Notes
spotify 1.2.3      55    latest/stable  snapcrafters -
EOF

cat >"${COMMANDS_DIR}/python-default-packages.txt" <<'EOF'
pip==24.0
setuptools==80.0
pytest==8.4
EOF

cat >"${COMMANDS_DIR}/python-virtualenvs.txt" <<'EOF'
/home/tester/git/util-repos/fedora-debugg/.venv/pyvenv.cfg
/home/tester/.virtualenvs/demo/pyvenv.cfg
EOF

cat >"${COMMANDS_DIR}/node-global-packages.txt" <<'EOF'
/home/tester/.local/lib/node_modules/typescript
/home/tester/.local/lib/node_modules/npm-check-updates
EOF

cat >"${COMMANDS_DIR}/node-project-manifests.txt" <<'EOF'
/home/tester/git/util-repos/clockwork/web/package.json
/home/tester/git/util-repos/fedora-debugg/ui/package.json
EOF

cat >"${COMMANDS_DIR}/go-cached-modules.txt" <<'EOF'
/home/tester/go/pkg/mod/cache/download/github.com/pkg/errors/@v/v0.9.1.mod
/home/tester/go/pkg/mod/cache/download/golang.org/x/sys/@v/v0.31.0.mod
/home/tester/go/pkg/mod/cache/download/golang.org/x/text/@v/v0.22.0.mod
EOF

cat >"${COMMANDS_DIR}/go-module-roots.txt" <<'EOF'
/home/tester/git/util-repos/short-circuit/go.mod
/home/tester/git/util-repos/pit-box/go.work
EOF

cat >"${SNAPSHOT_DIR}/security-posture/security-summary.md" <<'EOF'
# Security Posture Summary
- Fully present rows: 2
- Partial rows: 1
- Coverage gaps: 7
EOF

cat >"${SNAPSHOT_DIR}/security-posture/tables/security-tools.tsv" <<'EOF'
category	tool	command	command_status	command_path	packages	package_status	service	service_enabled	service_active	planned_deep_scan	phase1_assessment
malware	ClamAV scanner	clamscan	missing	-	clamav	missing	clamd.service	disabled	inactive	yes	gap
rootkit	Rootkit Hunter	rkhunter	missing	-	rkhunter	missing	-	-	-	yes	gap
integrity	AIDE	aide	missing	-	aide	missing	-	-	-	yes	gap
audit	auditctl	auditctl	present	/usr/bin/auditctl	audit	installed	auditd.service	enabled	active	yes	present
audit	ausearch	ausearch	present	/usr/bin/ausearch	audit	installed	-	-	-	no	present
baseline	OpenSCAP	oscap	present	/usr/bin/oscap	openscap-scanner,scap-security-guide	partial	-	-	-	yes	partial
EOF

"${ROOT_DIR}/scripts/analyze_snapshot.sh" "${SNAPSHOT_DIR}" >/dev/null

SUMMARY_FILE="${SNAPSHOT_DIR}/analysis-summary.md"
assert_file_exists "${SUMMARY_FILE}"
assert_contains "${SUMMARY_FILE}" "## Suspend Triage"
assert_contains "${SUMMARY_FILE}" "- Suspend requests captured: 3"
assert_contains "${SUMMARY_FILE}" "- Power/suspend-key or lid events captured: 1"
assert_contains "${SUMMARY_FILE}" "- GDM/default-idle timing matches: 2"
assert_contains "${SUMMARY_FILE}" "- GDM no-auto-suspend override: not present"
assert_contains "${SUMMARY_FILE}" "strongly indicating the GDM greeter's default idle-suspend policy"
assert_contains "${SUMMARY_FILE}" "## Resume Context"
assert_contains "${SUMMARY_FILE}" "## Recent Reboot Triage"
assert_contains "${SUMMARY_FILE}" "## Historical Coredump Trends"
assert_contains "${SUMMARY_FILE}" "## Xorg Comparison Readiness"
assert_contains "${SUMMARY_FILE}" "- Xorg comparison ready on this host: yes"
assert_contains "${SUMMARY_FILE}" "## BIOS / PCIe Topology"
assert_contains "${SUMMARY_FILE}" "- Board: ASUSTeK COMPUTER INC. PRIME Z390-P"
assert_contains "${SUMMARY_FILE}" "- CPU PEG root port appears empty: yes"
assert_contains "${SUMMARY_FILE}" "## NVIDIA Freeze Signals"
assert_contains "${SUMMARY_FILE}" "- Invalid-mmap burst windows: 1"
assert_contains "${SUMMARY_FILE}" "## GPU PCIe Link Evaluation"
assert_contains "${SUMMARY_FILE}" "- Degraded GPU link widths: 1"
assert_contains "${SUMMARY_FILE}" "0000:03:00.0 driver=nvidia width=4x/16x"
assert_contains "${SUMMARY_FILE}" "## GPU PCIe Load Probe"
assert_contains "${SUMMARY_FILE}" "- Workload: glxgears (timeout)"
assert_contains "${SUMMARY_FILE}" "- Width degraded during load: 1"
assert_contains "${SUMMARY_FILE}" "- Speed increased under load: yes"
assert_contains "${SUMMARY_FILE}" "## Mount State"
assert_contains "${SUMMARY_FILE}" "- Persistent Btrfs device counters captured: yes"
assert_contains "${SUMMARY_FILE}" "## Package Footprint"
assert_contains "${SUMMARY_FILE}" "- RPM packages: 3"
assert_contains "${SUMMARY_FILE}" "- Flatpak apps: 1"
assert_contains "${SUMMARY_FILE}" "- Flatpak runtimes: 2"
assert_contains "${SUMMARY_FILE}" "## Security Posture"
assert_contains "${SUMMARY_FILE}" "- Security posture inventory: captured"
assert_contains "${SUMMARY_FILE}" "- Fully present rows: 2"
assert_contains "${SUMMARY_FILE}" "- Partial rows: 1"
assert_contains "${SUMMARY_FILE}" "- Coverage gaps: 3"
assert_contains "${SUMMARY_FILE}" "- Malware coverage gap: yes"
assert_contains "${SUMMARY_FILE}" "- Audit/runtime coverage gap: no"
assert_contains "${SUMMARY_FILE}" "- Snap apps: 1"
assert_contains "${SUMMARY_FILE}" "## Language Footprint"
assert_contains "${SUMMARY_FILE}" "- Python packages (default interpreter): 3"
assert_contains "${SUMMARY_FILE}" "- Python virtualenvs: 2"
assert_contains "${SUMMARY_FILE}" "- Node global packages: 2"
assert_contains "${SUMMARY_FILE}" "- Node projects: 2"
assert_contains "${SUMMARY_FILE}" "- Go cached modules: 3"
assert_contains "${SUMMARY_FILE}" "- Go module/work roots: 2"
assert_contains "${SUMMARY_FILE}" "## Runtime/Profile/Wayland-GPU Triage"
assert_contains "${SUMMARY_FILE}" "- nvidia-smi state: failed"
assert_contains "${SUMMARY_FILE}" "- Codium/Electron crash indicators: 2"
