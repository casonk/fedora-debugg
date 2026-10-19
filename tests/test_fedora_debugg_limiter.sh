#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BIN="${TMP_DIR}/bin"
LOG="${TMP_DIR}/calls.log"
OUT="${TMP_DIR}/out.txt"
mkdir -p "${BIN}"
cat >"${BIN}/nvidia-smi" <<FAKE
#!/usr/bin/env bash
echo "nvidia-smi \$*" >>"${LOG}"
case "\$*" in
  *power.min_limit*) echo "100.00, 450.00" ;;
esac
FAKE
cat >"${BIN}/tuned-adm" <<FAKE
#!/usr/bin/env bash
echo "tuned-adm \$*" >>"${LOG}"
if [ "\$1" = list ]; then
  printf 'Available profiles:\n- balanced                    - General\n- powersave                   - Low power\nCurrent active profile: balanced\n'
fi
FAKE
chmod +x "${BIN}/nvidia-smi" "${BIN}/tuned-adm"

HELPER="${ROOT_DIR}/scripts/fedora-debugg-limiter"
export PATH="${BIN}:${PATH}"
export FEDORA_DEBUGG_LIMITER_CONF="${TMP_DIR}/etc/gpu-power-limit.conf"
export FEDORA_DEBUGG_LIMITER_UNIT="${TMP_DIR}/unit.service"

"${HELPER}" check >"${OUT}"
assert_contains "${OUT}" "ok"

# Without the boot unit the cap is applied but not persisted.
"${HELPER}" gpu-power 230 >"${OUT}"
assert_contains "${LOG}" "nvidia-smi --power-limit=230"
assert_contains "${OUT}" "until reboot"
if [ -e "${FEDORA_DEBUGG_LIMITER_CONF}" ]; then
  echo "expected no config without the unit" >&2
  exit 1
fi

touch "${FEDORA_DEBUGG_LIMITER_UNIT}"
"${HELPER}" gpu-power 260 >"${OUT}"
assert_contains "${FEDORA_DEBUGG_LIMITER_CONF}" "GPU_POWER_LIMIT_W=260"
assert_contains "${OUT}" "kept for future boots"

for bad in 99 451 25O "250;id" ""; do
  if "${HELPER}" gpu-power "${bad}" >"${OUT}" 2>&1; then
    echo "expected gpu-power '${bad}' to be refused" >&2
    exit 1
  fi
done
assert_contains "${FEDORA_DEBUGG_LIMITER_CONF}" "GPU_POWER_LIMIT_W=260"

"${HELPER}" profile powersave >"${OUT}"
assert_contains "${LOG}" "tuned-adm profile powersave"
for bad in throughput-performance "balanced;id" "../x" ""; do
  if "${HELPER}" profile "${bad}" >"${OUT}" 2>&1; then
    echo "expected profile '${bad}' to be refused" >&2
    exit 1
  fi
done

# Disk scheduler and read-ahead, against a fake /sys/block and udevadm.
SYS="${TMP_DIR}/sys/block"
mkdir -p "${SYS}/sdb/queue" "${SYS}/dm-2/queue" "${SYS}/nvme0n1/queue"
echo "mq-deadline kyber [bfq] none" >"${SYS}/sdb/queue/scheduler"
echo 8192 >"${SYS}/sdb/queue/read_ahead_kb"
echo 2048 >"${SYS}/dm-2/queue/read_ahead_kb"
cat >"${BIN}/udevadm" <<FAKE
#!/usr/bin/env bash
echo "udevadm \$*" >>"${LOG}"
case "\$*" in
  *--name=/dev/sdb*) echo "DEVTYPE=disk"; echo "ID_SERIAL=ST16000NT001-3LV101_ABC123" ;;
  *--name=/dev/dm-2*) echo "DEVTYPE=disk"; echo "DM_NAME=16tb-sata" ;;
  *--name=/dev/nvme0n1*) echo "DEVTYPE=disk"; echo 'ID_SERIAL=bad"serial' ;;
esac
FAKE
chmod +x "${BIN}/udevadm"
export FEDORA_DEBUGG_LIMITER_SYS_BLOCK="${SYS}"
RULES="${TMP_DIR}/etc/udev/rules.d/62-fedora-debugg-io-overrides.rules"
export FEDORA_DEBUGG_LIMITER_IO_RULES="${RULES}"

"${HELPER}" disk-scheduler sdb mq-deadline >"${OUT}"
assert_contains "${SYS}/sdb/queue/scheduler" "mq-deadline"
assert_contains "${RULES}" 'ENV{ID_SERIAL}=="ST16000NT001-3LV101_ABC123", ATTR{queue/scheduler}="mq-deadline"'
# Real sysfs keeps listing every scheduler after a write; the fake file does not.
echo "[mq-deadline] kyber bfq none" >"${SYS}/sdb/queue/scheduler"
"${HELPER}" disk-scheduler sdb bfq >"${OUT}"
if [ "$(grep -c 'queue/scheduler' "${RULES}")" != 1 ]; then
  echo "expected one scheduler override per disk" >&2
  exit 1
fi
assert_contains "${RULES}" 'ATTR{queue/scheduler}="bfq"'

"${HELPER}" read-ahead dm-2 4096 >"${OUT}"
assert_contains "${SYS}/dm-2/queue/read_ahead_kb" "4096"
assert_contains "${RULES}" 'ENV{DM_NAME}=="16tb-sata", ATTR{bdi/read_ahead_kb}="4096"'
assert_contains "${OUT}" "kept for future boots"

echo "mq-deadline kyber [bfq] none" >"${SYS}/sdb/queue/scheduler"
for bad in "sdb deadline-x" "sdb cfq" "dm-2 bfq" "sda1 bfq" "../sdb bfq" "sdb"; do
  # shellcheck disable=SC2086
  if "${HELPER}" disk-scheduler ${bad} >"${OUT}" 2>&1; then
    echo "expected disk-scheduler '${bad}' to be refused" >&2
    exit 1
  fi
done
for bad in "dm-2 100" "dm-2 32768" "sdb 4096;id" "dm-x 512" "nvme0n1 512"; do
  # shellcheck disable=SC2086
  if "${HELPER}" read-ahead ${bad} >"${OUT}" 2>&1; then
    echo "expected read-ahead '${bad}' to be refused" >&2
    exit 1
  fi
done

"${HELPER}" disk-reset sdb >"${OUT}"
if grep -q 'ST16000NT001' "${RULES}"; then
  echo "expected disk-reset to drop the disk's overrides" >&2
  exit 1
fi
assert_contains "${RULES}" 'DM_NAME}=="16tb-sata"'
assert_contains "${LOG}" "udevadm trigger --action=change --sysname-match=sdb"

if "${HELPER}" reboot >"${OUT}" 2>&1; then
  echo "expected an unknown command to fail" >&2
  exit 1
fi

# Installer against an alternate root.
ALT="${TMP_DIR}/root"
"${ROOT_DIR}/scripts/install_limiter_controls.sh" --root "${ALT}" --user alice >"${OUT}"
assert_file_exists "${ALT}/usr/local/sbin/fedora-debugg-limiter"
assert_contains "${ALT}/etc/sudoers.d/fedora-debugg-limiter" "alice ALL=(root) NOPASSWD: /usr/local/sbin/fedora-debugg-limiter"
if [ "$(stat -c %a "${ALT}/etc/sudoers.d/fedora-debugg-limiter")" != "440" ]; then
  echo "expected the sudoers rule to be mode 440" >&2
  exit 1
fi
if "${ROOT_DIR}/scripts/install_limiter_controls.sh" --root "${ALT}" --user 'bad user' >"${OUT}" 2>&1; then
  echo "expected an invalid user name to be refused" >&2
  exit 1
fi
"${ROOT_DIR}/scripts/install_limiter_controls.sh" --root "${ALT}" --uninstall >"${OUT}"
if [ -e "${ALT}/etc/sudoers.d/fedora-debugg-limiter" ] || [ -e "${ALT}/usr/local/sbin/fedora-debugg-limiter" ]; then
  echo "expected --uninstall to remove both files" >&2
  exit 1
fi
