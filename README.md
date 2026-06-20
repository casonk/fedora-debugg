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
- `scripts/export_tachometer_signals.sh`: Exports a compact Fedora-only sidecar JSON for `tachometer`.
- `scripts/archive_snapshots.sh`: Moves stale snapshots into a repo-local archive folder with restore support.
- `scripts/run_workflow.sh`: Runs collect + analyze in one command.
- `config/clockwork/crash-snapshot.toml`: Installable `clockwork` schedule for recurring snapshot collection.
- `scripts/log_session.sh`: Appends a human/agent session handoff entry.
- `scripts/vscodium_gpu.sh`: Enables/disables VSCodium GPU acceleration safely.
- `scripts/install_gdm_no_auto_suspend.sh`: Disables automatic suspend at the GDM login screen.
- `artifacts/`: Local snapshot output (ignored in git except `.gitkeep`).
- `CHATHISTORY.md`: Repo-root local handoff log for continuity (git-ignored).

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

To install the recurring user-level snapshot schedule through `clockwork`:

```bash
python3 -m clockwork.cli install --manifest config/clockwork/crash-snapshot.toml --target systemd-user
systemctl --user enable --now fedora-debugg-workflow.timer
```

> Requires `clockwork` to be installed or available on your Python path. See
> `./util-repos/clockwork` in the portfolio root.

For fuller system journals and kernel logs, run with elevated privileges:

```bash
sudo ./scripts/run_workflow.sh
```

## GDM Automatic Suspend

Terminal, SSH, and TTY activity does not reset the graphical GDM login
screen's idle timer. If the `Suspend Triage` summary reports repeated
GDM/default-idle timing matches, install the GDM-only no-auto-suspend policy:

```bash
sudo ./scripts/install_gdm_no_auto_suspend.sh
sudo systemctl reboot
```

This leaves intentional suspend available after login.

## SSH Identity Isolation

Interactive and automation SSH access should not share one broad private key.
The tracked hardening plan and repo-local example fragments live in:

- [docs/ssh-service-isolation-plan.md](docs/ssh-service-isolation-plan.md)
- [docs/ci-repair-agentic-auth-plan.md](docs/ci-repair-agentic-auth-plan.md)
- `config/security/ssh/config.example`
- `config/security/systemd/service-ssh-identity-example.service`

## Architecture Summary

`fedora-debugg` is built around a repeatable evidence pipeline rather than a
generic collection of shell scripts:

1. `scripts/run_workflow.sh` is the stable entrypoint.
2. `scripts/collect_snapshot.sh` captures host state into
   `artifacts/snapshot-<timestamp>/commands/` and refreshes `artifacts/latest`.
3. `scripts/analyze_snapshot.sh` turns that raw evidence into
   `analysis-summary.md`, with collection-health checks plus boot, GPU/Wayland,
   VSCodium, Btrfs, coredump, package-footprint, and Python/Node/Go language-footprint heuristics.
4. `scripts/log_session.sh` appends the local incident handoff in
   `CHATHISTORY.md`.
5. `scripts/vscodium_gpu.sh` is a targeted remediation helper when the summary
   points to the runtime/profile/Wayland-GPU cluster.
6. `scripts/export_tachometer_signals.sh` turns the latest snapshot into
   `artifacts/latest/tachometer-signals.json` so `tachometer` can render
   Fedora-specific alerts without owning Fedora heuristics. The export is
   bucketed into collection, display, coredump, GPU, storage, system-package,
   and Python/Node/Go language-footprint signals so generic warning volume does
   not dominate the dashboard.

Two sidecar audit lanes complement the incident flow:

- `scripts/analyze_storage_hardware.sh` for broader storage and hardware
  inspection.
- `scripts/analyze_installed_software.sh` for installed-software and runtime
  inventory reporting.

See [docs/architecture.md](docs/architecture.md) and
`docs/diagrams/repo-architecture.{puml,drawio}` for the repo-specific diagrams.

## Debugging Workflow

1. Reboot after a crash (if needed).
2. Run `./scripts/run_workflow.sh` as soon as possible.
3. Open the generated summary:
   - `artifacts/latest/analysis-summary.md`
4. Inspect matched lines in the underlying command outputs in:
   - `artifacts/latest/commands/`
5. If `tachometer` is running, confirm the sidecar export exists:
   - `artifacts/latest/tachometer-signals.json`
6. Review the last 3 boot cycles in the summary before assuming the system is stable again.
7. Repeat after each crash and compare patterns across snapshots.
8. Append a short handoff note:
   - `./scripts/log_session.sh --snapshot artifacts/latest --summary "what changed + what still broken"`

## Snapshot Archive Rotation

Crash snapshots in `artifacts/snapshot-*` are local-only evidence. To keep the
active artifacts directory small without deleting crash evidence, move stale
snapshots into the ignored repo-local archive:

```bash
./scripts/archive_snapshots.sh rotate
```

Defaults keep the newest 12 active snapshots and archive only snapshots at least
30 days old. `scripts/run_workflow.sh` runs this rotation after each successful
snapshot/analysis pass. Preview the rotation first with:

```bash
./scripts/archive_snapshots.sh rotate --dry-run
```

Archived snapshots move under `artifacts/archive/snapshots/`, and a TSV manifest
is written to `artifacts/archive/snapshot-manifest.tsv`. Restore a snapshot with:

```bash
./scripts/archive_snapshots.sh restore snapshot-YYYYMMDD-HHMMSS
```

Snapshots owned by another user are skipped and reported as `skip
foreign-owned`; change ownership or move them with the matching elevated command
only when you are sure that local evidence should be reorganized.


## GPU PCIe Load Probe

The normal workflow records negotiated GPU PCIe link state without stressing the
GPU. To confirm whether link speed and width change under load, run:

```bash
FEDORA_DEBUGG_GPU_PCIE_LOAD_PROBE=1 ./scripts/run_workflow.sh
```

The probe writes `commands/gpu-pcie-load-probe.txt` and the analyzer renders a
`GPU PCIe Load Probe` section. It uses `glmark2`, `vkmark`, `glxgears`, or
`vkcube` when a graphical display is available. For headless runs, set
`FEDORA_DEBUGG_GPU_PCIE_WORKLOAD` to a local command that creates GPU activity.
PCIe speed may rise under load as expected; PCIe width remaining below max
during load is the stronger hardware/slot/lane-allocation signal.

## Codium Crash Playbook (Wayland/GPU/Profile)

If summary points at `Runtime/Profile/Wayland-GPU`:

1. Isolate runtime vs profile:
   - `codium --disable-gpu --disable-extensions --user-data-dir /tmp/codium-clean-profile`
2. Toggle acceleration state with helper commands:
   - `./scripts/vscodium_gpu.sh status`
   - `./scripts/vscodium_gpu.sh disable`
   - `./scripts/vscodium_gpu.sh enable`
3. Re-enable extensions in small batches to identify a trigger.
4. Clear only caches, not user settings:
   - `~/.config/VSCodium/{GPUCache,Code Cache,CachedData,CachedExtensionVSIXs}`
5. If still unstable on Wayland, compare behavior in an Xorg session.
6. If `nvidia-smi` fails, repair the NVIDIA userspace/driver stack first.

The helper edits `~/.config/VSCodium/argv.json` and creates timestamped backups
before writing.

## Session History (Local Only)

Use repo-root `CHATHISTORY.md` as the running incident timeline so if the
machine crashes again, the next debug session can continue immediately.

- This file is intentionally git-ignored.
- Update it after every major action (driver change, kernel change, reboot,
  crash, new snapshot).

## Notes

- Snapshot files can include hostnames, usernames, mount paths, and process
  names. Treat `artifacts/` as sensitive local data.
- The current scripts are a starting point and will be extended with deeper
  heuristics and cross-snapshot diffing.
