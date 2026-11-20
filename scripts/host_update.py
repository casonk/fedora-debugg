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
             running and the load is low. After ``--force-after-days`` the load/busy guards
             are overridden; a manual hold file (``<state-dir>/hold-reboot``) is always honoured.
``notify``   the ordinary user, from a timer. Sends one alert per distinct condition through
             shock-relay: a blocked or failed upgrade, a reboot held or overdue, and a
             completed reboot (with whether the encrypted volumes came back).
``status``   print the state.

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


def run(cmd: list[str], timeout: int = 3600) -> subprocess.CompletedProcess[str]:
    """Run a command; a timeout or a missing binary is a failed result (124/127), never a crash."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)  # noqa: S603
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", f"timed out after {timeout}s")
    except OSError as exc:
        return subprocess.CompletedProcess(cmd, 127, "", str(exc))


def count_pending(dnf: str) -> int:
    out = run([dnf, "repoquery", "--upgrades", "-q"], 600)
    return len([line for line in out.stdout.splitlines() if line.strip()]) if out.returncode == 0 else 0


def tail(text: str, lines: int = 12) -> str:
    return "\n".join(text.strip().splitlines()[-lines:])


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

    blockers = run([str(SCRIPT_DIR / "detect_dnf_upgrade_blockers.sh"), "--dnf", args.dnf], 900)
    if blockers.returncode == 1:
        state.update(outcome="blocked", detail=tail(blockers.stdout, 14), upgraded=0)
        save_state(state_dir, state)
        print("blocked: a dependency conflict prevents the upgrade")
        return 2

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
    if check.returncode in (0, 1):
        needs = check.returncode == 1
    else:  # could not tell (dnf busy or hung): keep what we knew rather than guess
        needs = bool(state.get("reboot_required"))
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
        state.pop("reboot_required_since", None)
    save_state(state_dir, state)
    print(f"{mode}: {upgraded} package(s) upgraded; reboot {'required' if needs else 'not required'}")
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
    """Returns (decision, reason): reboot | none | deferred | held."""
    if not state.get("reboot_required"):
        return "none", "no reboot required"
    if (state_dir / "hold-reboot").exists():
        return "held", f"hold file present ({state_dir / 'hold-reboot'}): reboot manually"
    if state.get("outcome") in {"blocked", "failed"}:
        return "held", f"the last upgrade {state['outcome']}; not rebooting a half-updated system"
    since = parse_stamp(state.get("reboot_required_since")) or now
    overdue = now - since >= timedelta(days=args.force_after_days)
    if not overdue:
        busy = busy_processes(args.busy_pattern)
        if busy:
            return "deferred", f"busy: {busy[0]}"
        load = load_per_cpu()
        if load > args.max_load:
            return "deferred", f"load {load:.2f}/cpu is above {args.max_load}"
    return "reboot", "overdue, guards overridden" if overdue else "quiet window"


def cmd_reboot(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir)
    state = load_state(state_dir)
    now = datetime.now().astimezone()
    decision, reason = decide_reboot(state, state_dir, args, now)
    state.update(reboot_decision=decision, reboot_reason=reason, reboot_decision_at=stamp(now))
    if decision == "reboot" and not args.dry_run:
        message = (
            f"fedora-debugg: rebooting in {args.grace_minutes} min to finish updates "
            "(cancel with: shutdown -c)"
        )
        result = run([args.shutdown, "-r", f"+{args.grace_minutes}", message], 60)
        if result.returncode != 0:
            state.update(reboot_decision="failed", reboot_reason=tail(result.stderr or result.stdout, 3))
            save_state(state_dir, state)
            print(f"reboot failed: {state['reboot_reason']}")
            return 1
        state["reboot_scheduled_at"] = stamp(now)
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
    if state.get("reboot_decision") == "held":
        alerts.append((
            f"reboot-held:{state.get('reboot_required_since')}:{state.get('reboot_reason')}",
            "fedora-debugg: reboot needed but held",
            f"Updates need a reboot (since {state.get('reboot_required_since')}) but it is held: "
            f"{state.get('reboot_reason')}.",
        ))
    since = parse_stamp(state.get("reboot_required_since"))
    if state.get("reboot_required") and since and now - since >= timedelta(days=stale_days):
        alerts.append((
            f"reboot-overdue:{state['reboot_required_since']}",
            "fedora-debugg: reboot overdue",
            f"A reboot has been required since {state['reboot_required_since']} "
            f"({(now - since).days} days). Last decision: {state.get('reboot_decision')} "
            f"({state.get('reboot_reason')}).",
        ))
    scheduled = parse_stamp(state.get("reboot_scheduled_at"))
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
    up.set_defaults(func=cmd_upgrade)

    rb = sub.add_parser("reboot", help="reboot when required and safe (root)")
    rb.add_argument("--dry-run", action="store_true")
    rb.add_argument("--grace-minutes", type=int, default=5)
    rb.add_argument("--max-load", type=float, default=0.7, help="1-minute load per CPU")
    rb.add_argument("--force-after-days", type=int, default=7)
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
