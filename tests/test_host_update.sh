#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
if [ "${KEEP_TMP:-0}" != "1" ]; then trap 'rm -rf "${TMP_DIR}"' EXIT; fi
HU="${ROOT_DIR}/scripts/host_update.py"
MOCK="${TMP_DIR}/mock"; mkdir -p "${MOCK}"

# A fake dnf: MOCK_PENDING counts upgrades, MOCK_REBOOT=1 makes needs-restarting -r exit 1,
# MOCK_BLOCK=1 reproduces a soname-bump conflict, MOCK_FAIL=1 makes the upgrade itself fail.
cat >"${MOCK}/dnf" <<'DNF'
#!/usr/bin/env bash
echo "$*" >>"${MOCK_LOG}"
case "$1" in
  update)
    if [ "${MOCK_BLOCK:-0}" = 1 ]; then
      echo "Problem: installed package ttyd-1.7.7-7.fc43.x86_64 requires libwebsockets.so.20()(64bit), but none of the providers can be installed"
      exit 1
    fi
    echo "Nothing to do."; exit 0 ;;
  repoquery) n="$(cat "${MOCK_PENDING_FILE}")"; for i in $(seq 1 "${n}"); do echo "pkg$i-1.0-1.fc43.x86_64"; done ;;
  upgrade) [ "${MOCK_FAIL:-0}" = 1 ] && { echo "Transaction failed: disk full"; exit 1; }; echo 0 >"${MOCK_PENDING_FILE}" ;;
  needs-restarting) [ "${MOCK_REBOOT:-0}" = 1 ] && exit 1 || exit 0 ;;
esac
DNF
cat >"${MOCK}/shutdown" <<'SD'
#!/usr/bin/env bash
echo "$*" >>"${MOCK_LOG}.shutdown"
SD
cat >"${MOCK}/fwupdmgr" <<'FW'
#!/usr/bin/env bash
case "$1" in
  get-updates)
    if [ "${MOCK_FW:-none}" = updates ]; then
      echo '{"Devices":[{"Name":"System Firmware","Releases":[{"Version":"9.9.9"}]}]}'; exit 0
    elif [ "${MOCK_FW:-none}" = broken ]; then echo "daemon not running" >&2; exit 1; fi
    exit 2 ;;
esac
exit 0
FW
chmod +x "${MOCK}/dnf" "${MOCK}/shutdown" "${MOCK}/fwupdmgr"

new_case() {  # new_case NAME PENDING
  CASE="${TMP_DIR}/$1"; mkdir -p "${CASE}"
  export MOCK_LOG="${CASE}/dnf.log" MOCK_PENDING_FILE="${CASE}/pending" STATE="${CASE}/state"
  echo "$2" >"${MOCK_PENDING_FILE}"; : >"${MOCK_LOG}"
  unset MOCK_BLOCK MOCK_FAIL MOCK_REBOOT MOCK_FW FEDORA_DEBUGG_LOAD
}
upgrade() { python3 "${HU}" --state-dir "${STATE}" upgrade --dnf "${MOCK}/dnf" --fwupdmgr "${MOCK}/fwupdmgr" "$@"; }
reboot_cmd() { python3 "${HU}" --state-dir "${STATE}" reboot --shutdown "${MOCK}/shutdown" "$@"; }
jget() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "${STATE}/state.json" "$1"; }
expect() { [ "$(jget "$1")" = "$2" ] || fail "state.$1 = '$(jget "$1")', expected '$2'"; }

# --- upgrade: a security run applies updates and records a required reboot ------------
new_case ok 8; export MOCK_REBOOT=1
upgrade --mode security
assert_contains "${MOCK_LOG}" "upgrade --refresh -y --security"
expect outcome updated; expect upgraded 8; expect reboot_required True; expect mode security
[ -n "$(jget reboot_required_since)" ] || fail "reboot_required_since not set"
since="$(jget reboot_required_since)"
echo 3 >"${MOCK_PENDING_FILE}"; upgrade --mode full   # a later run keeps the original 'since'
assert_contains "${MOCK_LOG}" "upgrade --refresh -y"
expect reboot_required_since "${since}"; expect mode full

# --- nothing to do, and a cleared reboot requirement ----------------------------------
new_case nothing 0; upgrade --mode security
expect outcome nothing; expect reboot_required False

# --- a blocker stops the run before anything is installed -----------------------------
new_case blocked 5; export MOCK_BLOCK=1
rc=0; upgrade --mode security || rc=$?
[ "${rc}" = 2 ] || fail "blocked upgrade should exit 2, got ${rc}"
expect outcome blocked; assert_not_contains "${MOCK_LOG}" "upgrade --refresh"

# --- a failing upgrade is recorded with the tail of dnf's output ----------------------
new_case failed 5; export MOCK_FAIL=1
rc=0; upgrade --mode security || rc=$?
[ "${rc}" = 1 ] || fail "failed upgrade should exit 1, got ${rc}"
expect outcome failed; grep -q "disk full" "${STATE}/state.json" || fail "detail missing dnf output"

# --- needs-restarting that hangs or errors keeps the previous answer instead of guessing -------
new_case unsure 8; export MOCK_REBOOT=1; upgrade --mode security >/dev/null; unset MOCK_REBOOT
expect reboot_required True
cat >"${MOCK}/dnf-unsure" <<'DNF2'
#!/usr/bin/env bash
case "$1" in
  repoquery) ;;
  needs-restarting) exit 5 ;;
  *) exit 0 ;;
esac
DNF2
chmod +x "${MOCK}/dnf-unsure"
python3 "${HU}" --state-dir "${STATE}" upgrade --dnf "${MOCK}/dnf-unsure" --mode security >/dev/null
expect reboot_required True

# --- auto mode: full on Sunday, security otherwise ------------------------------------
python3 - "${HU}" <<'PY'
import importlib.util, sys
from datetime import datetime
spec = importlib.util.spec_from_file_location("hu", sys.argv[1]); hu = importlib.util.module_from_spec(spec); spec.loader.exec_module(hu)
assert hu.resolve_mode("auto", datetime(2026, 11, 22)) == "full"      # Sunday
assert hu.resolve_mode("auto", datetime(2026, 11, 20)) == "security"  # Friday
assert hu.resolve_mode("full", datetime(2026, 11, 20)) == "full"
PY

# --- reboot decisions -------------------------------------------------------------------
needs_reboot() { new_case "$1" 8; export MOCK_REBOOT=1; upgrade --mode security >/dev/null; unset MOCK_REBOOT; }

new_case none 0; upgrade --mode security >/dev/null
reboot_cmd; expect reboot_decision none; assert_file_not_exists "${MOCK_LOG}.shutdown"

needs_reboot quiet
export FEDORA_DEBUGG_LOAD=0.1
reboot_cmd --busy-pattern 'no-such-process-xyz'
expect reboot_decision reboot; assert_contains "${MOCK_LOG}.shutdown" "-r +360"; expect reboot_scheduled_at "$(jget reboot_scheduled_at)"

needs_reboot dry; export FEDORA_DEBUGG_LOAD=0.1
reboot_cmd --dry-run --busy-pattern 'no-such-process-xyz'
expect reboot_decision reboot; assert_file_not_exists "${MOCK_LOG}.shutdown"

needs_reboot busy; export FEDORA_DEBUGG_LOAD=0.1
sleep 77 & busy_pid=$!
reboot_cmd --busy-pattern 'sleep 77'
kill "${busy_pid}" 2>/dev/null || true
expect reboot_decision deferred; assert_file_not_exists "${MOCK_LOG}.shutdown"

needs_reboot loaded; export FEDORA_DEBUGG_LOAD=5
reboot_cmd --busy-pattern 'no-such-process-xyz'
expect reboot_decision deferred; assert_file_not_exists "${MOCK_LOG}.shutdown"

needs_reboot overdue; export FEDORA_DEBUGG_LOAD=5
python3 - "${STATE}/state.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["reboot_required_since"] = "2020-01-01T00:00:00+00:00"; json.dump(s, open(p, "w"))
PY
reboot_cmd --busy-pattern '.'   # busy AND loaded, but overdue: guards are overridden
expect reboot_decision reboot; assert_contains "${MOCK_LOG}.shutdown" "-r +360"

needs_reboot hold; export FEDORA_DEBUGG_LOAD=0.1; touch "${STATE}/hold-reboot"
reboot_cmd --force-after-days 0 --busy-pattern 'no-such-process-xyz'   # even overdue, a hold wins
expect reboot_decision held; assert_file_not_exists "${MOCK_LOG}.shutdown"

new_case halfdone 8; export MOCK_FAIL=1; upgrade --mode security >/dev/null || true; unset MOCK_FAIL
python3 - "${STATE}/state.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["reboot_required"] = True; json.dump(s, open(p, "w"))
PY
reboot_cmd --busy-pattern 'no-such-process-xyz'
expect reboot_decision held; assert_file_not_exists "${MOCK_LOG}.shutdown"

# --- notify: once per condition, only through channels that have a target ---------------
RELAY="${TMP_DIR}/relay"; mkdir -p "${RELAY}/services/signal-cli" "${RELAY}/services/gmail-imap"
cat >"${RELAY}/services/signal-cli/send_message.py" <<'PY'
import sys
open(__import__("os").environ["RELAY_LOG"], "a").write("signal|" + sys.argv[2].replace("\n", " / ") + "\n")
PY
cat >"${RELAY}/services/gmail-imap/send_email.py" <<'PY'
import sys
sys.exit(3)
PY
export RELAY_LOG="${TMP_DIR}/relay.log" FEDORA_DEBUGG_SHOCK_RELAY_ROOT="${RELAY}"
export FEDORA_DEBUGG_NOTIFY_SIGNAL_TARGET=x FEDORA_DEBUGG_NOTIFY_GMAIL_TARGET=y
export FEDORA_DEBUGG_BOOT_TIME="2020-01-01T00:00:00+00:00"
notify() { python3 "${HU}" --state-dir "${STATE}" notify --sent-file "${TMP_DIR}/sent.json"; }

new_case alert 5; export MOCK_BLOCK=1; upgrade --mode security >/dev/null || true; unset MOCK_BLOCK
: >"${RELAY_LOG}"; rm -f "${TMP_DIR}/sent.json"
notify >"${TMP_DIR}/notify.out"
assert_contains "${RELAY_LOG}" "host upgrade blocked"
assert_contains "${TMP_DIR}/notify.out" "alert via gmail: "      # a failing channel is reported, not fatal
notify >/dev/null
[ "$(grep -c 'host upgrade blocked' "${RELAY_LOG}")" = 1 ] || fail "the same blocked upgrade alerted twice"

# a changed detail is a new condition; a cleared one is forgotten and can alert again
: >"${RELAY_LOG}"; upgrade --mode security >/dev/null || true   # still blocked, same detail: no new alert
notify >/dev/null; assert_not_contains "${RELAY_LOG}" "blocked"
echo 5 >"${MOCK_PENDING_FILE}"; upgrade --mode security >/dev/null   # unblocked
notify >/dev/null
export MOCK_BLOCK=1; upgrade --mode security >/dev/null || true; unset MOCK_BLOCK
notify >/dev/null; assert_contains "${RELAY_LOG}" "host upgrade blocked"

# an overdue reboot alerts once
needs_reboot stale
python3 - "${STATE}/state.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["reboot_required_since"] = "2020-01-01T00:00:00+00:00"; json.dump(s, open(p, "w"))
PY
: >"${RELAY_LOG}"; rm -f "${TMP_DIR}/sent.json"; notify >/dev/null
assert_contains "${RELAY_LOG}" "reboot overdue"

# a completed reboot is reported with the unlock state, once
python3 - "${STATE}/state.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["reboot_scheduled_at"] = "2020-06-01T00:00:00+00:00"; s["reboot_from_kernel"] = "7.3.3"; json.dump(s, open(p, "w"))
PY
export FEDORA_DEBUGG_BOOT_TIME="2020-06-01T00:10:00+00:00"
: >"${RELAY_LOG}"; notify >/dev/null
assert_contains "${RELAY_LOG}" "rebooted for updates"; assert_contains "${RELAY_LOG}" "luks-volumes.service"
: >"${RELAY_LOG}"; notify >/dev/null; assert_not_contains "${RELAY_LOG}" "rebooted for updates"

# without any target nothing is sent and nothing is marked as sent
unset FEDORA_DEBUGG_NOTIFY_SIGNAL_TARGET FEDORA_DEBUGG_NOTIFY_GMAIL_TARGET
: >"${RELAY_LOG}"; rm -f "${TMP_DIR}/sent.json"; notify >"${TMP_DIR}/none.out"
assert_contains "${TMP_DIR}/none.out" "no FEDORA_DEBUGG_NOTIFY"

export FEDORA_DEBUGG_NOTIFY_SIGNAL_TARGET=x FEDORA_DEBUGG_NOTIFY_GMAIL_TARGET=y
# a scheduled reboot asks for approval with full-path commands, once, and not again after it happened
needs_reboot sched; export FEDORA_DEBUGG_LOAD=0.1
reboot_cmd --busy-pattern 'no-such-process-xyz'
: >"${RELAY_LOG}"; rm -f "${TMP_DIR}/sent.json"; notify >/dev/null
assert_contains "${RELAY_LOG}" "approval requested"
assert_contains "${RELAY_LOG}" "/usr/bin/sudo /usr/sbin/shutdown -r now"
assert_contains "${RELAY_LOG}" "/usr/bin/sudo /usr/sbin/shutdown -c"
: >"${MOCK_LOG}.shutdown"; reboot_cmd --busy-pattern 'no-such-process-xyz'    # a second run does not reschedule
expect reboot_decision scheduled; [ ! -s "${MOCK_LOG}.shutdown" ] || fail "rescheduled an already scheduled reboot"

# firmware: available updates are reported, never applied; an unreachable fwupd is "unavailable"
new_case fw 3; export MOCK_FW=updates; upgrade --mode security >/dev/null
python3 -c 'import json,sys;f=json.load(open(sys.argv[1]))["firmware"];assert f["status"]=="updates" and f["updates"]==["System Firmware -> 9.9.9"],f' "${STATE}/state.json"
: >"${RELAY_LOG}"; rm -f "${TMP_DIR}/sent.json"; notify >/dev/null
assert_contains "${RELAY_LOG}" "firmware update available"; assert_contains "${RELAY_LOG}" "/usr/bin/sudo /usr/bin/fwupdmgr update"
export MOCK_FW=broken; upgrade --mode security >/dev/null
python3 -c 'import json,sys;assert json.load(open(sys.argv[1]))["firmware"]["status"]=="unavailable"' "${STATE}/state.json"
unset MOCK_FW; upgrade --mode security >/dev/null
python3 -c 'import json,sys;assert json.load(open(sys.argv[1]))["firmware"]["status"]=="current"' "${STATE}/state.json"

echo "host_update tests passed"
