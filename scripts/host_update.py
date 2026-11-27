#!/usr/bin/env python3
"""Keep the Fedora host patched, and reboot it only when that is needed and safe.

Subcommands (all share one state file, ``<state-dir>/state.json``):

``upgrade``  root, from a timer. Pre-checks for soname-bump blockers, runs ``dnf upgrade``
             (``--mode security`` daily; ``full`` weekly; ``auto`` = full on Sunday else
             security), then records what changed and whether a reboot is now required.
             Firmware is never touched: ignition binds LUKS auto-unlock to TPM2 PCR 7
             (Secure Boot state), which only a firmware/Secure-Boot-database update moves.
``reboot``   root, from a timer in a quiet window. Reboots (with a cancellable grace
             period) only when the last upgrade left a reboot required, nothing heavy is
             running and the load is low. A routine requirement (no Critical or Important
             advisory on a package that needs the reboot) waits ``--defer-days`` calendar
             days; an urgent one, or one that cannot be rated, goes the same night. After ``--force-after-days`` the load/busy guards
             are overridden; a manual hold file (``<state-dir>/hold-reboot``) is always honoured.
``notify``   the ordinary user, from a timer. Sends one alert per distinct condition through
             shock-relay: a blocked or failed upgrade, a reboot planned, held or overdue, and a
             completed reboot (with whether the encrypted volumes came back).
``status``   print the state.

Reboots are never abrupt: the root job schedules one ``--grace-minutes`` ahead (default 6 h)
and the notifier tells the user, with the exact full-path commands to approve it now
(``/usr/sbin/shutdown -r now``) or cancel it (``/usr/sbin/shutdown -c``). Firmware is only
*checked* (BIOS version plus ``fwupdmgr get-updates``) and reported, never applied.

A dnf upgrade that is blocked or fails changes nothing and is alerted, never retried blindly.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

DEFAULT_STATE_DIR = "/var/lib/fedora-debugg/host-update"
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_BUSY = r"dnf5? |rpm |podman build|container_rotation|restic|ffmpeg|pytest"
URGENT_SEVERITIES = "critical,important"
DEFER_DAYS = 2
# Everything recorded about one outstanding reboot requirement; a boot satisfies it.
REQUIREMENT_KEYS = (
    "reboot_required_since",
    "reboot_packages",
    "reboot_urgency",
    "reboot_urgent_packages",
    "reboot_planned_for",
)
CHANNELS = ("signal", "telegram", "gmail")
SERVICE_SCRIPTS = {
    "signal": "services/signal-cli/send_message.py",
    "telegram": "services/telegram/send_message.py",
    "gmail": "services/gmail-imap/send_email.py",
}


def stamp(when: datetime | None = None) -> str:
    return (when or datetime.now().astimezone()).isoformat(timespec="seconds")


def parse_stamp(value: str | None) -> datetime | None:
    try:
        return datetime.fromisoformat(value) if value else None
    except ValueError:
        return None


def load_state(state_dir: Path) -> dict:
    try:
        data = json.loads((state_dir / "state.json").read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(state_dir: Path, state: dict) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    temporary = state_dir / "state.json.tmp"
    temporary.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.chmod(0o644)  # world-readable: the user-level notifier reads it
    os.replace(temporary, state_dir / "state.json")


def requirement_is_stale(state: dict, booted: datetime) -> bool:
    """True when the host has booted since the requirement was first recorded."""
    since = parse_stamp(state.get("reboot_required_since"))
    return since is not None and since <= booted


def clear_requirement(state: dict) -> None:
    state["reboot_required"] = False
    for key in REQUIREMENT_KEYS:
        state.pop(key, None)


def run(cmd: list[str], timeout: int = 3600) -> subprocess.CompletedProcess[str]:
    """Run a command; a timeout or a missing binary is a failed result (124/127), never a crash."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)  # noqa: S603
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", f"timed out after {timeout}s")
    except OSError as exc:
        return subprocess.CompletedProcess(cmd, 127, "", str(exc))


def firmware_check(fwupdmgr: str, dmi_dir: str | None = None) -> dict:
    """Report the BIOS version and any fwupd firmware updates. Never applies anything."""
    dmi = Path(dmi_dir or os.environ.get("FEDORA_DEBUGG_DMI_DIR", "/sys/class/dmi/id"))

    def field(name: str) -> str:
        try:
            return (dmi / name).read_text(encoding="utf-8").strip()
        except OSError:
            return ""

    info: dict = {
        "bios_version": field("bios_version"),
        "bios_date": field("bios_date"),
        "board": f"{field('board_vendor')} {field('board_name')}".strip(),
        "checked_at": stamp(),
        "updates": [],
    }
    run([fwupdmgr, "refresh", "--force"], 180)
    out = run([fwupdmgr, "get-updates", "--json", "--no-unreported-check"], 180)
    if out.returncode == 0:
        try:
            for device in json.loads(out.stdout).get("Devices", []):
                for release in device.get("Releases", []):
                    info["updates"].append(f"{device.get('Name', '?')} -> {release.get('Version', '?')}")
        except ValueError:
            info["status"] = "unavailable"
            return info
        info["status"] = "updates" if info["updates"] else "current"
    elif out.returncode == 2:  # fwupdmgr: nothing to do
        info["status"] = "current"
    else:
        info["status"] = "unavailable"
        info["note"] = tail(out.stderr or out.stdout, 2)
    return info


def count_pending(dnf: str) -> int:
    out = run([dnf, "repoquery", "--upgrades", "-q"], 600)
    return len([line for line in out.stdout.splitlines() if line.strip()]) if out.returncode == 0 else 0


def tail(text: str, lines: int = 12) -> str:
    return "\n".join(text.strip().splitlines()[-lines:])


# -- urgency ----------------------------------------------------------------------------


def advisory_nevras(dnf: str, scope: str, severities: str) -> set[str] | None:
    """Packages (name-version-release.arch) named by advisories of these severities; None if unknown."""
    cmd = [dnf, "advisory", "list", scope, f"--advisory-severities={severities}", "--json"]
    out = run(cmd + (["--refresh"] if scope == "--updates" else []), 600)
    if out.returncode != 0:
        return None
    try:
        return {re.sub(r"-\d+:", "-", item["nevra"]) for item in json.loads(out.stdout)}
    except (ValueError, KeyError, TypeError):
        return None


def installed_since(rpm: str, booted: datetime) -> set[str] | None:
    out = run([rpm, "-qa", "--qf", "%{INSTALLTIME} %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\\n"], 300)
    if out.returncode != 0:
        return None
    rows = (line.split() for line in out.stdout.splitlines())
    return {row[1] for row in rows if len(row) == 2 and row[0].isdigit() and int(row[0]) > booted.timestamp()}


def package_name(nevra: str) -> str:
    return nevra.rsplit("-", 2)[0]


def rate_requirement(args: argparse.Namespace, state: dict, triggers: list[str], pending: set[str] | None) -> None:
    """Record whether the outstanding reboot is urgent, routine or unknown.

    Two views are combined: advisories pending *before* this upgrade (which also covers a jump
    over an intermediate fix) and advisories on versions installed since boot (which also covers
    updates applied by hand). Once a package is urgent it stays so until the reboot.
    """
    installed = advisory_nevras(args.dnf, "--installed", args.urgent_severities)
    recent = installed_since(args.rpm, boot_time())
    rated = (pending or set()) | ((installed or set()) & (recent or set()))
    urgent = set(state.get("reboot_urgent_packages") or [])
    urgent |= {package_name(nevra) for nevra in rated} & set(triggers)
    known = bool(triggers) and None not in (pending, installed, recent)
    state["reboot_packages"] = triggers
    state["reboot_urgent_packages"] = sorted(urgent)
    state["reboot_urgency"] = "urgent" if urgent else "routine" if known else "unknown"


# -- upgrade ----------------------------------------------------------------------------


def resolve_mode(mode: str, today: datetime | None = None) -> str:
    if mode != "auto":
        return mode
    return "full" if (today or datetime.now()).weekday() == 6 else "security"


def cmd_upgrade(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    with open(state_dir / "lock", "w", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("another host update is running")
            return 0
        return _upgrade(args, state_dir)


def _upgrade(args: argparse.Namespace, state_dir: Path) -> int:
    state = load_state(state_dir)
    mode = resolve_mode(args.mode)
    state.update(checked_at=stamp(), mode=mode)
    if requirement_is_stale(state, boot_time()):
        clear_requirement(state)

    blockers = run([str(SCRIPT_DIR / "detect_dnf_upgrade_blockers.sh"), "--dnf", args.dnf], 900)
    if blockers.returncode == 1:
        state.update(outcome="blocked", detail=tail(blockers.stdout, 14), upgraded=0)
        save_state(state_dir, state)
        print("blocked: a dependency conflict prevents the upgrade")
        return 2

    pending_urgent = advisory_nevras(args.dnf, "--updates", args.urgent_severities)
    before = count_pending(args.dnf)
    cmd = [args.dnf, "upgrade", "--refresh", "-y"] + (["--security"] if mode == "security" else [])
    result = run(cmd)
    if result.returncode != 0:
        state.update(outcome="failed", detail=tail(result.stdout + result.stderr), upgraded=0)
        save_state(state_dir, state)
        print(f"failed: dnf exited {result.returncode}")
        return 1
    after = count_pending(args.dnf)
    upgraded = max(before - after, 0)

    check = run([args.dnf, "needs-restarting", "-r"], 300)
    if check.returncode == 1:
        needs = True
        triggers = re.findall(r"^\s*\*\s+(\S+)", check.stdout, re.MULTILINE)
        rate_requirement(args, state, triggers, pending_urgent)
    elif check.returncode == 0:
        needs = False
    else:  # could not tell (dnf busy or hung): keep what we knew rather than guess
        needs = bool(state.get("reboot_required"))
        if needs and state.get("reboot_urgency") == "routine":
            state["reboot_urgency"] = "unknown"  # this run's updates were never rated
    state["firmware"] = firmware_check(args.fwupdmgr)
    state.update(
        outcome="updated" if upgraded else "nothing",
        detail="",
        upgraded=upgraded,
        pending_after=after,
        kernel_running=run(["uname", "-r"]).stdout.strip(),
        reboot_required=needs,
    )
    if needs and not state.get("reboot_required_since"):
        state["reboot_required_since"] = stamp()
    if not needs:
        clear_requirement(state)
    save_state(state_dir, state)
    verdict = f"required ({state.get('reboot_urgency', 'unknown')})" if needs else "not required"
    print(f"{mode}: {upgraded} package(s) upgraded; reboot {verdict}")
    return 0


# -- reboot -----------------------------------------------------------------------------


def busy_processes(pattern: str) -> list[str]:
    ps = run(["ps", "-eo", "pid,args"], 30).stdout.splitlines()
    me = str(os.getpid())
    found = []
    for line in ps:
        pid, _, command = line.strip().partition(" ")
        if pid != me and re.search(pattern, command) and "host_update.py" not in command:
            found.append(command.strip()[:80])
    return found


def load_per_cpu() -> float:
    override = os.environ.get("FEDORA_DEBUGG_LOAD")
    if override:
        return float(override)
    return os.getloadavg()[0] / (os.cpu_count() or 1)


def decide_reboot(state: dict, state_dir: Path, args: argparse.Namespace, now: datetime) -> tuple[str, str]:
    """Returns (decision, reason): reboot | none | waiting | deferred | held."""
    if not state.get("reboot_required"):
        return "none", "no reboot required"
    if requirement_is_stale(state, boot_time()):
        return "none", "already rebooted since the requirement was recorded"
    if (state_dir / "hold-reboot").exists():
        return "held", f"hold file present ({state_dir / 'hold-reboot'}): reboot manually"
    if state.get("outcome") in {"blocked", "failed"}:
        return "held", f"the last upgrade {state['outcome']}; not rebooting a half-updated system"
    since = parse_stamp(state.get("reboot_required_since")) or now
    overdue = now - since >= timedelta(days=args.force_after_days)
    if not overdue:
        planned = (since + timedelta(days=args.defer_days)).date()
        if state.get("reboot_urgency") == "routine" and now.date() < planned:
            return "waiting", f"not urgent: planned for the {planned.isoformat()} reboot window"
        busy = busy_processes(args.busy_pattern)
        if busy:
            return "deferred", f"busy: {busy[0]}"
        load = load_per_cpu()
        if load > args.max_load:
            return "deferred", f"load {load:.2f}/cpu is above {args.max_load}"
    if overdue:
        return "reboot", "overdue, guards overridden"
    return "reboot", "quiet window"


def cmd_reboot(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    state = load_state(state_dir)
    now = datetime.now().astimezone()
    decision, reason = decide_reboot(state, state_dir, args, now)
    if requirement_is_stale(state, boot_time()):
        clear_requirement(state)
    state.pop("reboot_planned_for", None)
    if decision == "waiting":
        planned = parse_stamp(state.get("reboot_required_since")) or now
        state["reboot_planned_for"] = (planned + timedelta(days=args.defer_days)).date().isoformat()
    state.update(reboot_decision=decision, reboot_reason=reason, reboot_decision_at=stamp(now))
    if decision == "reboot":
        pending = parse_stamp(state.get("reboot_at"))
        scheduled = parse_stamp(state.get("reboot_scheduled_at"))
        if pending and scheduled and pending > now and scheduled > boot_time():
            decision, reason = "scheduled", f"a reboot is already scheduled for {state['reboot_at']}"
            state.update(reboot_decision=decision, reboot_reason=reason, reboot_decision_at=stamp(now))
    if decision == "reboot" and not args.dry_run:
        message = (
            f"fedora-debugg: rebooting in {args.grace_minutes} min to finish updates "
            "(cancel with: /usr/sbin/shutdown -c)"
        )
        result = run([args.shutdown, "-r", f"+{args.grace_minutes}", message], 60)
        if result.returncode != 0:
            state.update(reboot_decision="failed", reboot_reason=tail(result.stderr or result.stdout, 3))
            save_state(state_dir, state)
            print(f"reboot failed: {state['reboot_reason']}")
            return 1
        state["reboot_scheduled_at"] = stamp(now)
        state["reboot_at"] = stamp(now + timedelta(minutes=args.grace_minutes))
        state["reboot_from_kernel"] = run(["uname", "-r"]).stdout.strip()
    save_state(state_dir, state)
    print(f"{decision}: {reason}")
    return 0


# -- notify (ordinary user) ---------------------------------------------------------------


def shock_relay_root() -> Path:
    override = os.environ.get("FEDORA_DEBUGG_SHOCK_RELAY_ROOT")
    return Path(override).expanduser() if override else SCRIPT_DIR.parents[1] / "shock-relay"


def send_alert(subject: str, body: str) -> list[tuple[str, str | None]]:
    results = []
    for channel in CHANNELS:
        target = os.environ.get(f"FEDORA_DEBUGG_NOTIFY_{channel.upper()}_TARGET", "").strip()
        if not target:
            continue
        script = shock_relay_root() / SERVICE_SCRIPTS[channel]
        if not script.exists():
            results.append((channel, f"shock-relay script not found: {script}"))
            continue
        command = [sys.executable, str(script), target] + (
            [subject, body] if channel == "gmail" else [f"{subject}\n{body}"]
        )
        config = os.environ.get(f"FEDORA_DEBUGG_NOTIFY_{channel.upper()}_CONFIG", "").strip()
        if config:
            command += ["--config", config]
        try:
            out = subprocess.run(  # noqa: S603
                command, capture_output=True, text=True, timeout=60, check=False,
                env={**os.environ, "PYTHONPATH": str(script.parent)},
            )  # fmt: skip
            error = None if out.returncode == 0 else (out.stderr or out.stdout).strip().splitlines()[-1:] or ["failed"]
            results.append((channel, error if error is None else error[0]))
        except (OSError, subprocess.SubprocessError) as exc:
            results.append((channel, str(exc)))
    return results


def boot_time() -> datetime:
    override = os.environ.get("FEDORA_DEBUGG_BOOT_TIME")
    if override:
        return datetime.fromisoformat(override)
    return datetime.fromtimestamp(time.time() - float(Path("/proc/uptime").read_text().split()[0])).astimezone()


def luks_state() -> str:
    out = subprocess.run(["systemctl", "is-active", "luks-volumes.service"], capture_output=True, text=True, check=False)  # noqa: S603,S607
    return out.stdout.strip() or "unknown"


def pending_alerts(state: dict, sent: dict, now: datetime, stale_days: int, booted: datetime, luks: str) -> list[tuple[str, str, str]]:
    """(key, subject, body) for each condition not yet alerted."""
    alerts = []
    outcome = state.get("outcome")
    if outcome in {"blocked", "failed"}:
        digest = hashlib.sha256(str(state.get("detail", "")).encode()).hexdigest()[:10]
        alerts.append((
            f"upgrade-{outcome}:{digest}",
            f"fedora-debugg: host upgrade {outcome}",
            f"The {state.get('mode', '')} upgrade on {state.get('checked_at', '?')} {outcome}.\n"
            f"Nothing was changed.\n\n{state.get('detail', '')}",
        ))  # fmt: skip
    required = bool(state.get("reboot_required")) and not requirement_is_stale(state, booted)
    needed_by = ", ".join(state.get("reboot_packages") or []) or "not recorded"
    urgent = ", ".join(state.get("reboot_urgent_packages") or [])
    if urgent:
        rating = f"Urgent: a Critical or Important advisory covers {urgent}."
    elif state.get("reboot_urgency") == "routine":
        rating = "Routine: no Critical or Important advisory on these packages."
    else:
        rating = "Urgency could not be rated, so it is treated as urgent."
    if required and state.get("reboot_decision") == "waiting":
        alerts.append((
            f"reboot-planned:{state.get('reboot_required_since')}",
            "fedora-debugg: reboot planned",
            f"Updates need a reboot, but not urgently. Needed by: {needed_by}.\n{rating}\n\n"
            f"It will be scheduled in the {state.get('reboot_planned_for')} reboot window, with the usual "
            "grace period, and sooner if an urgent update arrives.\n\n"
            "Reboot now:   /usr/bin/sudo /usr/sbin/shutdown -r now\n"
            f"Hold it:      /usr/bin/sudo /usr/bin/touch {Path(DEFAULT_STATE_DIR) / 'hold-reboot'}\n"
            "Doing nothing keeps the plan.",
        ))  # fmt: skip
    if required and state.get("reboot_decision") == "held":
        alerts.append((
            f"reboot-held:{state.get('reboot_required_since')}:{state.get('reboot_reason')}",
            "fedora-debugg: reboot needed but held",
            f"Updates need a reboot (since {state.get('reboot_required_since')}) but it is held: "
            f"{state.get('reboot_reason')}.",
        ))
    since = parse_stamp(state.get("reboot_required_since"))
    waiting = state.get("reboot_decision") == "waiting"
    if required and not waiting and since and now - since >= timedelta(days=stale_days):
        alerts.append((
            f"reboot-overdue:{state['reboot_required_since']}",
            "fedora-debugg: reboot overdue",
            f"A reboot has been required since {state['reboot_required_since']} "
            f"({(now - since).days} days). Last decision: {state.get('reboot_decision')} "
            f"({state.get('reboot_reason')}).",
        ))
    scheduled = parse_stamp(state.get("reboot_scheduled_at"))
    due_at = parse_stamp(state.get("reboot_at"))
    if scheduled and due_at and booted < scheduled and now < due_at:
        alerts.append((
            f"reboot-scheduled:{state['reboot_scheduled_at']}",
            "fedora-debugg: reboot scheduled, approval requested",
            f"Updates need a reboot. It is scheduled for {state['reboot_at']}.\n"
            f"Needed by: {needed_by}.\n{rating}\n\n"
            "Approve now:  /usr/bin/sudo /usr/sbin/shutdown -r now\n"
            "Cancel it:    /usr/bin/sudo /usr/sbin/shutdown -c\n"
            f"Hold future:  /usr/bin/sudo /usr/bin/touch {Path(DEFAULT_STATE_DIR) / 'hold-reboot'}\n"
            "Doing nothing lets it proceed at the scheduled time.",
        ))
    firmware = state.get("firmware") or {}
    if firmware.get("status") == "updates":
        listed = "\n".join(firmware["updates"])
        alerts.append((
            f"firmware:{listed}",
            "fedora-debugg: firmware update available (not applied)",
            f"fwupd offers:\n{listed}\n\nFirmware is never applied automatically (it can change the TPM "
            "Secure Boot measurement that unlocks the encrypted volumes). Review it, then apply it by "
            "hand with /usr/bin/sudo /usr/bin/fwupdmgr update.",
        ))
    if scheduled and booted > scheduled:
        alerts.append((
            f"rebooted:{state['reboot_scheduled_at']}",
            "fedora-debugg: rebooted for updates",
            f"Rebooted after updates (was on kernel {state.get('reboot_from_kernel')}). "
            f"Encrypted volumes (luks-volumes.service): {luks}.",
        ))
    return [a for a in alerts if a[0] not in sent]


def cmd_notify(args: argparse.Namespace) -> int:
    state = load_state(Path(args.state_dir))
    sent_file = Path(os.path.expanduser(args.sent_file))
    try:
        sent = json.loads(sent_file.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        sent = {}
    now = datetime.now().astimezone()
    due = pending_alerts(state, sent, now, args.stale_days, boot_time(), luks_state())
    for key, subject, body in due:
        results = send_alert(subject, body)
        for channel, error in results:
            print(f"alert via {channel}: {'sent' if error is None else error}")
        if not results:
            print(f"alert not sent (no FEDORA_DEBUGG_NOTIFY_*_TARGET configured): {subject}")
        elif any(error is None for _, error in results):
            sent[key] = stamp(now)
    # forget alerts for conditions that cleared, so they notify again if they return
    live = {key for key, _, _ in pending_alerts(state, {}, now, args.stale_days, boot_time(), "x")}
    sent = {k: v for k, v in sent.items() if k in live or k.startswith("rebooted:")}
    sent_file.parent.mkdir(parents=True, exist_ok=True)
    sent_file.write_text(json.dumps(sent, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    sent_file.chmod(0o600)
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    print(json.dumps(load_state(Path(args.state_dir)), indent=2, sort_keys=True))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--state-dir", default=os.environ.get("FEDORA_DEBUGG_STATE_DIR", DEFAULT_STATE_DIR))
    sub = parser.add_subparsers(dest="command", required=True)

    up = sub.add_parser("upgrade", help="apply updates (root)")
    up.add_argument("--mode", choices=["security", "full", "auto"], default="auto")
    up.add_argument("--dnf", default="dnf")
    up.add_argument("--rpm", default="rpm")
    up.add_argument("--urgent-severities", default=URGENT_SEVERITIES, help="advisory severities rebooted the same night")
    up.add_argument("--fwupdmgr", default="fwupdmgr")
    up.set_defaults(func=cmd_upgrade)

    rb = sub.add_parser("reboot", help="reboot when required and safe (root)")
    rb.add_argument("--dry-run", action="store_true")
    rb.add_argument("--grace-minutes", type=int, default=360)
    rb.add_argument("--max-load", type=float, default=0.7, help="1-minute load per CPU")
    rb.add_argument("--force-after-days", type=int, default=7)
    rb.add_argument("--defer-days", type=int, default=DEFER_DAYS, help="calendar days a routine reboot waits")
    rb.add_argument("--busy-pattern", default=os.environ.get("FEDORA_DEBUGG_REBOOT_BUSY", DEFAULT_BUSY))
    rb.add_argument("--shutdown", default="shutdown")
    rb.set_defaults(func=cmd_reboot)

    nt = sub.add_parser("notify", help="send alerts (ordinary user)")
    nt.add_argument("--stale-days", type=int, default=3)
    nt.add_argument("--sent-file", default="~/.local/state/fedora-debugg/host-update-notify.json")
    nt.set_defaults(func=cmd_notify)

    st = sub.add_parser("status", help="print the state")
    st.set_defaults(func=cmd_status)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
