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
  "${HOME_DIR}/.cache" \
  "${HOME_DIR}/.local/share/Trash/files" \
  "${FIXTURE_ROOT}/var-cache-dnf" \
  "${FIXTURE_ROOT}/journal" \
  "${FIXTURE_ROOT}/coredump" \
  "${MOCK_BIN}"

cat >"${MOCK_BIN}/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "+%Y%m%d-%H%M%S" ]; then
  printf '20260102-020304\n'
elif [ "${1:-}" = "--iso-8601=seconds" ]; then
  printf '2026-01-02T02:03:04+00:00\n'
else
  /usr/bin/date "$@"
fi
EOF

cat >"${MOCK_BIN}/getent" <<EOF
#!/usr/bin/env bash
printf 'tester:x:1000:1000:Tester User:%s:/bin/bash\n' "${HOME_DIR}"
EOF

cat >"${MOCK_BIN}/findmnt" <<'EOF'
#!/usr/bin/env bash
printf 'TARGET="/" SOURCE="/dev/md0" FSTYPE="btrfs" OPTIONS="rw,relatime,compress=zstd:1"\n'
printf 'TARGET="/home" SOURCE="/dev/md0" FSTYPE="btrfs" OPTIONS="rw,relatime,compress=zstd:1"\n'
printf 'TARGET="/mnt/archive" SOURCE="/dev/sdb1" FSTYPE="ext4" OPTIONS="rw,relatime"\n'
EOF

cat >"${MOCK_BIN}/df" <<'EOF'
#!/usr/bin/env bash
printf 'Mounted on     Type      1B-blocks       Used   Available Use%%\n'
printf '/              btrfs    1000000000 900000000   100000000  90%%\n'
printf '/home          btrfs    2000000000 1000000000 1000000000  50%%\n'
printf '/mnt/archive   ext4     5000000000 1000000000 4000000000  20%%\n'
EOF

cat >"${MOCK_BIN}/lsblk" <<'EOF'
#!/usr/bin/env bash
printf 'PATH="/dev/nvme0n1" SIZE="1000000000" ROTA="0" DISC-GRAN="4096" TYPE="disk" TRAN="nvme" MODEL="Fast Drive" SERIAL="NVME0001" REV="FW100"\n'
printf 'PATH="/dev/nvme1n1" SIZE="1000000000" ROTA="0" DISC-GRAN="4096" TYPE="disk" TRAN="nvme" MODEL="Mirror Drive" SERIAL="NVME0002" REV="FW200"\n'
EOF

cat >"${MOCK_BIN}/journalctl" <<'EOF'
#!/usr/bin/env bash
printf 'Archived and active journals take up 300.0M in the file system.\n'
EOF

cat >"${MOCK_BIN}/rpm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-q" ]; then
  printf 'kernel-core-6.8.1-1.fc43.x86_64\t120000000\n'
  printf 'kernel-core-6.8.2-1.fc43.x86_64\t120000000\n'
  printf 'kernel-core-6.8.3-1.fc43.x86_64\t120000000\n'
  exit 0
fi
exit 1
EOF

cat >"${MOCK_BIN}/du" <<EOF
#!/usr/bin/env bash
set -euo pipefail
target="\${!#}"
case "\${target}" in
  "${HOME_DIR}/.cache")
    printf '400000000\t%s\n' "${HOME_DIR}/.cache"
    ;;
  "${HOME_DIR}/.local/share/Trash")
    printf '250000000\t%s\n' "${HOME_DIR}/.local/share/Trash"
    ;;
  "${FIXTURE_ROOT}/var-cache-dnf")
    printf '600000000\t%s\n' "${FIXTURE_ROOT}/var-cache-dnf"
    ;;
  "${FIXTURE_ROOT}/journal")
    printf '300000000\t%s\n' "${FIXTURE_ROOT}/journal"
    ;;
  "${FIXTURE_ROOT}/coredump")
    printf '100000000\t%s\n' "${FIXTURE_ROOT}/coredump"
    ;;
  "/")
    printf '900000000\t/\n'
    printf '500000000\t/var\n'
    printf '300000000\t/home\n'
    printf '100000000\t/usr\n'
    ;;
  "/home")
    printf '1000000000\t/home\n'
    printf '700000000\t/home/tester\n'
    printf '300000000\t/home/shared\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat >"${MOCK_BIN}/btrfs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "filesystem" ] && [ "${2:-}" = "show" ]; then
  printf "Label: 'mock-root'  uuid: deadbeef\n"
  printf '\tTotal devices 2 FS bytes used 1000000000\n'
  printf '\tdevid    1 size 1000000000 used 600000000 path /dev/nvme0n1p2\n'
  printf '\tdevid    2 size 1000000000 used 400000000 path /dev/nvme1n1p2\n'
  exit 0
fi
if [ "${1:-}" = "filesystem" ] && [ "${2:-}" = "usage" ]; then
  printf 'Data,single: Size:1073741824, Used:536870912\n'
  printf 'Metadata,DUP: Size:536870912, Used:268435456\n'
  printf '/dev/nvme0n1p2 used 600000000\n'
  printf '/dev/nvme1n1p2 used 400000000\n'
  exit 0
fi
if [ "${1:-}" = "balance" ] && [ "${2:-}" = "status" ]; then
  printf "No balance found on '%s'\n" "${3:-/}"
  exit 0
fi
exit 1
EOF

cat >"${MOCK_BIN}/smartctl" <<'EOF'
#!/usr/bin/env bash
printf 'SMART overall-health self-assessment test result: PASSED\n'
EOF

cat >"${MOCK_BIN}/fwupdmgr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "get-devices" ]; then
  printf 'NVMe Drive\n  Current version: FW100\n'
  exit 0
fi
if [ "${1:-}" = "get-updates" ]; then
  printf 'Upgrade available for NVMe Drive\n  New version: FW110\n'
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
export STORAGE_AUDIT_TOP_PATH_TARGETS="/:/home"
export STORAGE_AUDIT_CLEANUP_PATHS="${HOME_DIR}/.cache:${HOME_DIR}/.local/share/Trash:${FIXTURE_ROOT}/var-cache-dnf:${FIXTURE_ROOT}/journal:${FIXTURE_ROOT}/coredump"

REPORT_DIR="$("${ROOT_DIR}/scripts/analyze_storage_hardware.sh" --output-dir "${OUTPUT_DIR}" --top-limit 3 --path-only)"

assert_file_exists "${REPORT_DIR}/storage-summary.md"
assert_file_exists "${REPORT_DIR}/tables/mounts.tsv"
assert_file_exists "${REPORT_DIR}/tables/cleanup-candidates.tsv"
assert_file_exists "${REPORT_DIR}/tables/hardware-devices.tsv"
assert_file_exists "${REPORT_DIR}/tables/btrfs-layout.tsv"
assert_file_exists "${REPORT_DIR}/tables/firmware-status.tsv"
assert_file_not_exists "${REPORT_DIR}/commands/du--mnt-archive.txt"

assert_contains "${REPORT_DIR}/storage-summary.md" "- Mounts analyzed: 3"
assert_contains "${REPORT_DIR}/storage-summary.md" "- Cleanup candidates detected: 6"
assert_contains "${REPORT_DIR}/storage-summary.md" "- Firmware update status: available"
assert_contains "${REPORT_DIR}/tables/mounts.tsv" $'/\tbtrfs\t/dev/md0\t1000000000\t900000000'
assert_contains "${REPORT_DIR}/tables/cleanup-candidates.tsv" "${FIXTURE_ROOT}/var-cache-dnf"
assert_contains "${REPORT_DIR}/tables/cleanup-candidates.tsv" $'medium\tkernel-packages\tkernel-core (older installs)'
assert_contains "${REPORT_DIR}/tables/hardware-devices.tsv" $'/dev/nvme0n1\tdisk\tnvme'
assert_contains "${REPORT_DIR}/tables/btrfs-layout.tsv" $'/\t2\tsingle\tDUP\tidle\tconsider-restripe'
assert_contains "${REPORT_DIR}/tables/firmware-status.tsv" $'available\tUpgrade available for NVMe Drive'
