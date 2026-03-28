# Fedora Debug Repo Architecture

This document maps the repeatable evidence-collection and triage workflow that
keeps `fedora-debugg` actionable. The real implementation is the
capture-to-summary-to-handoff loop plus a pair of sidecar audit scripts, not
just the top-level `scripts/` folder.

## Visual diagrams

- `docs/diagrams/repo-architecture.puml`
- `docs/diagrams/repo-architecture.drawio`

## Main execution lane

1. **Snapshot orchestration (`scripts/run_workflow.sh`).**
   The stable operator entrypoint runs collection first, validates that a
   snapshot directory was created, and then invokes the analyzer against that
   exact snapshot.
2. **Collection (`scripts/collect_snapshot.sh`).**
   Captures the host state into `artifacts/snapshot-<timestamp>/commands/`,
   including reboot history, `journalctl`, `dmesg`, package state, display
   session state, GPU tooling, and VSCodium config. It also refreshes the
   `artifacts/latest` pointer and writes a local bundle README.
3. **Analysis (`scripts/analyze_snapshot.sh`).**
   Reads the captured command outputs and writes `analysis-summary.md`, which is
   the repo's main synthesized triage surface. The analyzer is where recurring
   heuristics live: boot-window review, GPU and Wayland signals, VSCodium
   runtime/profile hints, Btrfs counters, coredump trends, and summary-ready
   match sections.
4. **Targeted remediation helper (`scripts/vscodium_gpu.sh`).**
   This is not part of the main collection pipeline, but it is an important
   operational branch: when the summary points to the runtime/profile/Wayland-GPU
   cluster, the helper can safely inspect or toggle
   `disable-hardware-acceleration` in `~/.config/VSCodium/argv.json`, creating
   backups before writes.
5. **Handoff (`scripts/log_session.sh`).**
   Sessions append the latest diagnosis, kernel, driver, and next action to the
   repo-root `CHATHISTORY.md` so a later investigation can resume without
   rebuilding context from scratch.

## Sidecar audit lanes

- **Storage and hardware audit (`scripts/analyze_storage_hardware.sh`).**
  Produces a broader hardware-oriented report when the crash loop suggests
  device, filesystem, or controller-level follow-up beyond the snapshot summary.
- **Installed software audit (`scripts/analyze_installed_software.sh`).**
  Produces a package/runtime inventory report for cases where repo operators
  need a reproducible view of the installed software surface around an
  instability window.

These sidecar analyzers are separate from `run_workflow.sh`; they should appear
in the architecture as adjacent audit lanes rather than being collapsed into the
main crash-snapshot pipeline.

## Artifact tiers

- `artifacts/snapshot-<timestamp>/commands/`: Just-in-time diagnostic captures
  per incident run.
- `artifacts/latest`: Convenience pointer to the most recent snapshot.
- `analysis-summary.md`: Human-readable triage, including collection health,
  resume context, restart history, the three most recent boots, GPU/Xwayland
  flags, Btrfs counters, and coredump trends.
- sidecar report directories from `analyze_storage_hardware.sh` and
  `analyze_installed_software.sh`: deeper on-demand audit output.
- `CHATHISTORY.md`: Lightweight repo-root handoff log keyed by ISO timestamps;
  never committed upstream.

## Signal layers and heuristics

- **Boot triage:** The collection defaults preserve the last three boot windows,
  and each new `analysis-summary` keeps the `current`, `prev-1`, and `prev-2`
  perspective visible.
- **Graphics stack:** `analyze_snapshot.sh` tags `Xwayland lost`, `VSYNC`
  warnings, `trap int3`, `SIGSEGV`, and `NVRM: VM: invalid mmap` bursts. Those
  findings are the handoff point into `vscodium_gpu.sh`, driver work, or X11
  comparison.
- **Storage counters:** `btrfs device stats /` and related evidence are surfaced
  in the summary so contributors can distinguish legacy corruption counters from
  new activity.
- **Observability:** `nvidia-smi`, `glxinfo`, session metadata, and reboot logs
  are captured every run so the triage path is evidence-first rather than
  anecdote-first.

## Key scripts

- `scripts/run_workflow.sh`: entry point for the crash-snapshot loop.
- `scripts/collect_snapshot.sh`: capture layer and artifact writer.
- `scripts/analyze_snapshot.sh`: heuristic analyzer and summary generator.
- `scripts/log_session.sh`: local continuity writer.
- `scripts/vscodium_gpu.sh`: targeted remediation helper.
- `scripts/analyze_storage_hardware.sh`: sidecar hardware/storage audit lane.
- `scripts/analyze_installed_software.sh`: sidecar software-inventory audit lane.

## Validation surface

- `tests/test_analyze_snapshot.sh`
- `tests/test_analyze_storage_hardware.sh`
- `tests/test_analyze_installed_software.sh`
- `.github/workflows/ci.yml`

The tests are centered on the analyzers and shell behavior, which matches the
real architecture: the repo's durable value is in the repeatable capture and
triage logic rather than in a long-running service.

## Collaboration posture

- Additive, reversible edits only; evidence files stay local under `artifacts/`.
- Avoid reorganizing existing logs or manual resets. When new heuristics or
  detectors are added, keep them small and well-documented inside
  `scripts/analyze_snapshot.sh`.
- Keep the diagrams centered on the evidence pipeline, sidecar audit lanes, and
  continuity loop unless the repo gains a materially different orchestration
  layer.
