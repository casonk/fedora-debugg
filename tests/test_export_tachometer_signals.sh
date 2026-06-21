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

cat >"${COMMANDS_DIR}/journal-current-warn.txt" <<'EOF'
# Timestamp: 2026-04-09T10:00:00-04:00
# Command: journalctl -b -p warning..emerg --no-pager -n 2500

Apr 09 10:00:01 host kernel: NVRM: VM: invalid mmap
Apr 09 10:00:01 host kernel: NVRM: VM: invalid mmap
Apr 09 10:00:02 host systemd-coredump[9]: Process 99 (gnome-shell) of user 1000 dumped core.

# Exit status: 0
EOF

cat >"${COMMANDS_DIR}/journal-kernel-current.txt" <<'EOF'
Apr 09 10:00:01 host kernel: NVRM: VM: invalid mmap
Apr 09 10:00:03 host kernel: NVRM: Xid (PCI:0000:03:00): 56, CMDre 00000000
Apr 09 10:00:04 host kernel: BTRFS info (device nvme0n1p3): bdev /dev/nvme0n1p3 errs: wr 0, rd 21, flush 0, corrupt 350, gen 0
EOF

cat >"${COMMANDS_DIR}/journal-prev-warn.txt" <<'EOF'
Apr 09 09:58:00 host gnome-shell[8]: Connection to xwayland lost
EOF

cat >"${COMMANDS_DIR}/findmnt.txt" <<'EOF'
/ /dev/nvme0n1p3[/root] btrfs rw,relatime
/home /dev/nvme0n1p3[/home] btrfs rw,relatime
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

cat >"${COMMANDS_DIR}/nvidia-smi.txt" <<'EOF'
NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.
# Exit status: 1
EOF

cat >"${COMMANDS_DIR}/gpu-pcie-links.txt" <<'EOF'
pci_device=0000:03:00.0
vendor=0x10de
device=0x2204
current_link_speed=2.5 GT/s PCIe
current_link_width=4
max_link_speed=16.0 GT/s PCIe
max_link_width=16
driver=nvidia

EOF

cat >"${COMMANDS_DIR}/coredump-list.txt" <<'EOF'
TIME                           PID  UID  GID SIG COREFILE EXE
Thu 2026-04-09 10:00:02 EDT     99 1000 1000 11 present  /usr/bin/gnome-shell
Thu 2026-04-09 10:00:03 EDT    100 1000 1000 11 present  /usr/bin/Xwayland
EOF

cat >"${COMMANDS_DIR}/dmesg.txt" <<'EOF'
# Exit status: 1
EOF

cat >"${SNAPSHOT_DIR}/analysis-summary.md" <<'EOF'
# Crash Analysis Summary
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

OUTPUT_PATH="${SNAPSHOT_DIR}/tachometer-signals.json"
"${ROOT_DIR}/scripts/export_tachometer_signals.sh" --snapshot-dir "${SNAPSHOT_DIR}" --output "${OUTPUT_PATH}" >/dev/null

assert_file_exists "${OUTPUT_PATH}"
assert_contains "${OUTPUT_PATH}" '"source": "fedora-debugg"'
assert_contains "${OUTPUT_PATH}" '"schema_version": 3'
assert_contains "${OUTPUT_PATH}" '"command_failure_count": 2'
assert_contains "${OUTPUT_PATH}" '"display_instability_count": 1'
assert_contains "${OUTPUT_PATH}" '"current_coredump_marker_count": 1'
assert_contains "${OUTPUT_PATH}" '"coredump_history_count": 2'
assert_contains "${OUTPUT_PATH}" '"nvidia_fault_count": 2'
assert_contains "${OUTPUT_PATH}" '"nvml_failure_count": 1'
assert_contains "${OUTPUT_PATH}" '"gpu_pcie_link_count": 1'
assert_contains "${OUTPUT_PATH}" '"gpu_pcie_degraded_count": 1'
assert_contains "${OUTPUT_PATH}" '"gpu_pcie_alert": true'
assert_contains "${OUTPUT_PATH}" '"pcie_links": 1'
assert_contains "${OUTPUT_PATH}" '"pcie_degraded": 1'
assert_contains "${OUTPUT_PATH}" '"btrfs_error_counter_count": 1'
assert_contains "${OUTPUT_PATH}" '"root_mount_mode": "rw"'
assert_contains "${OUTPUT_PATH}" '"collection": "yellow"'
assert_contains "${OUTPUT_PATH}" '"display": "yellow"'
assert_contains "${OUTPUT_PATH}" '"coredumps": "red"'
assert_contains "${OUTPUT_PATH}" '"gpu": "red"'
assert_contains "${OUTPUT_PATH}" '"storage": "yellow"'
assert_contains "${OUTPUT_PATH}" '"label": "Collection"'
assert_contains "${OUTPUT_PATH}" '"summary": "2 command failures"'
assert_contains "${OUTPUT_PATH}" '"label": "Display"'
assert_contains "${OUTPUT_PATH}" '"summary": "1 instability markers"'
assert_contains "${OUTPUT_PATH}" '"label": "Storage"'
assert_contains "${OUTPUT_PATH}" '"summary": "btrfs counters"'
assert_contains "${OUTPUT_PATH}" '"rpm_package_count": 3'
assert_contains "${OUTPUT_PATH}" '"flatpak_app_count": 1'
assert_contains "${OUTPUT_PATH}" '"flatpak_runtime_count": 2'
assert_contains "${OUTPUT_PATH}" '"snap_app_count": 1'
assert_contains "${OUTPUT_PATH}" '"packages": "green"'
assert_contains "${OUTPUT_PATH}" '"security_present_count": 2'
assert_contains "${OUTPUT_PATH}" '"security_partial_count": 1'
assert_contains "${OUTPUT_PATH}" '"security_gap_count": 3'
assert_contains "${OUTPUT_PATH}" '"security_malware_gap": true'
assert_contains "${OUTPUT_PATH}" '"security_audit_runtime_gap": false'
assert_contains "${OUTPUT_PATH}" '"security": "yellow"'
assert_contains "${OUTPUT_PATH}" '"label": "Security"'
assert_contains "${OUTPUT_PATH}" '"summary": "2 present / 1 partial / 3 gaps"'
assert_contains "${OUTPUT_PATH}" '"label": "Packages"'
assert_contains "${OUTPUT_PATH}" '"summary": "rpm 3 / flatpak 1 / snap 1"'
assert_contains "${OUTPUT_PATH}" '"python_package_count": 3'
assert_contains "${OUTPUT_PATH}" '"python_virtualenv_count": 2'
assert_contains "${OUTPUT_PATH}" '"node_global_package_count": 2'
assert_contains "${OUTPUT_PATH}" '"node_project_count": 2'
assert_contains "${OUTPUT_PATH}" '"go_cached_module_count": 3'
assert_contains "${OUTPUT_PATH}" '"go_module_root_count": 2'
assert_contains "${OUTPUT_PATH}" '"python": "green"'
assert_contains "${OUTPUT_PATH}" '"node": "green"'
assert_contains "${OUTPUT_PATH}" '"go": "green"'
assert_contains "${OUTPUT_PATH}" '"label": "Python"'
assert_contains "${OUTPUT_PATH}" '"summary": "3 pkgs / 2 envs"'
assert_contains "${OUTPUT_PATH}" '"label": "Node"'
assert_contains "${OUTPUT_PATH}" '"summary": "2 global / 2 proj"'
assert_contains "${OUTPUT_PATH}" '"label": "Go"'
assert_contains "${OUTPUT_PATH}" '"summary": "3 mods / 2 roots"'
assert_contains "${OUTPUT_PATH}" '"overall_light": "red"'

ARTIFACTS_DIR="${TMP_DIR}/repo-artifacts"

mkdir -p "${ARTIFACTS_DIR}/latest/commands"
cp "${COMMANDS_DIR}"/*.txt "${ARTIFACTS_DIR}/latest/commands/"
cp "${SNAPSHOT_DIR}/analysis-summary.md" "${ARTIFACTS_DIR}/latest/analysis-summary.md"
mkdir -p "${ARTIFACTS_DIR}/latest/security-posture/tables"
cp "${SNAPSHOT_DIR}/security-posture/tables/security-tools.tsv" "${ARTIFACTS_DIR}/latest/security-posture/tables/security-tools.tsv"

real_dir_output="$(FEDORA_DEBUGG_ARTIFACTS_DIR="${ARTIFACTS_DIR}" "${ROOT_DIR}/scripts/export_tachometer_signals.sh")"
printf '%s\n' "${real_dir_output}" >"${TMP_DIR}/real-dir-output.txt"
assert_contains "${TMP_DIR}/real-dir-output.txt" "tachometer-signals.json"
assert_file_exists "${ARTIFACTS_DIR}/latest/tachometer-signals.json"
