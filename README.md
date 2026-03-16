# Fedora Workstation Crash Debugging

This repository is a local toolkit for investigating Fedora workstation crashes
(freeze, sudden reboot, kernel panic, graphical lockups, and app crashes).

## Goals

- Capture useful system evidence quickly after a crash/reboot.
- Keep debugging artifacts organized by timestamp.
- Start triage automatically so likely root causes surface early.

## Repository Layout

- `scripts/collect_snapshot.sh`: Collects logs and system state into a snapshot.
- `scripts/analyze_snapshot.sh`: Scans a snapshot for common crash signatures.
- `scripts/run_workflow.sh`: Runs collect + analyze in one command.
- `scripts/log_session.sh`: Appends a human/agent session handoff entry.
- `artifacts/`: Local snapshot output (ignored in git except `.gitkeep`).
- `local/chat-history.md`: Local handoff log for continuity (git-ignored).

## Runtime/Profile/Wayland-GPU Focus

The workflow now captures and triages a dedicated issue cluster for:

- Electron/Codium runtime crashes (`SIGSEGV`, `SIGTRAP`, `SIGILL`, `trap int3`)
- Wayland/Xwayland compositor instability signals
- NVIDIA runtime/NVML health failures
- VSCodium profile/runtime config (`argv.json`, settings, extensions)

See the generated section:

- `artifacts/latest/analysis-summary.md` -> `Runtime/Profile/Wayland-GPU Triage`

## Quick Start

```bash
./scripts/run_workflow.sh
```

For fuller system journals and kernel logs, run with elevated privileges:

```bash
sudo ./scripts/run_workflow.sh
```

## Debugging Workflow

1. Reboot after a crash (if needed).
2. Run `./scripts/run_workflow.sh` as soon as possible.
3. Open the generated summary:
   - `artifacts/latest/analysis-summary.md`
4. Inspect matched lines in the underlying command outputs in:
   - `artifacts/latest/commands/`
5. Repeat after each crash and compare patterns across snapshots.
6. Append a short handoff note:
   - `./scripts/log_session.sh --snapshot artifacts/latest --summary "what changed + what still broken"`

## Codium Crash Playbook (Wayland/GPU/Profile)

If summary points at `Runtime/Profile/Wayland-GPU`:

1. Isolate runtime vs profile:
   - `codium --disable-gpu --disable-extensions --user-data-dir /tmp/codium-clean-profile`
2. If stable, persist safe runtime flags in `~/.config/VSCodium/argv.json`:
   - `{ "disable-hardware-acceleration": true, "ozone-platform-hint": "x11" }`
3. Re-enable extensions in small batches to identify a trigger.
4. Clear only caches, not user settings:
   - `~/.config/VSCodium/{GPUCache,Code Cache,CachedData,CachedExtensionVSIXs}`
5. If still unstable on Wayland, compare behavior in an Xorg session.
6. If `nvidia-smi` fails, repair the NVIDIA userspace/driver stack first.

## Session History (Local Only)

Use `local/chat-history.md` as the running incident timeline so if the machine
crashes again, the next debug session can continue immediately.

- This file is intentionally git-ignored.
- Update it after every major action (driver change, kernel change, reboot,
  crash, new snapshot).

## Notes

- Snapshot files can include hostnames, usernames, mount paths, and process
  names. Treat `artifacts/` as sensitive local data.
- The current scripts are a starting point and will be extended with deeper
  heuristics and cross-snapshot diffing.
