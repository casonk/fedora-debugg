# Contributor Architecture Blueprint

This document maps the repeatable evidence-collection and triage workflow that keeps the Fedora debug repo actionable. It mirrors the contributor blueprint structure used in `personal-finance/docs/contributor-architecture-blueprint.md`, but focuses on this repo’s capture→triage→handoff loop.

## Visual diagrams

- none yet; consider adding `docs/diagrams/repo-architecture.drawio` once the flow stabilizes.

## High-level pipeline

1. **Snapshot orchestration (`scripts/run_workflow.sh`).** The single entrypoint executes `collect_snapshot.sh` to capture boot logs, installed package lists, GPU/Kerner outputs, etc., and then pipes the generated `artifacts/<timestamp>` directory into `analyze_snapshot.sh`.
2. **Collection (`scripts/collect_snapshot.sh`).** Reads key diagnostics, enforces the “last 3 boots” mandate, and deposits raw outputs under `artifacts/<snapshot>/commands/` plus metadata like `last-reboots.txt` and `uname.txt`. The CLI exposes `--path-only` so other scripts (or tests) can reuse the same timestamped folder.
3. **Analysis (`scripts/analyze_snapshot.sh`).** Enriches the raw commands with classifiers (boot triage, GPU/Wayland signals, storage counters) and writes `analysis-summary.md`. New heuristics for Codium/Wayland/NVIDIA or Btrfs correlators are added here as we discover recurring patterns.
4. **Handoff (`scripts/log_session.sh`).** Sessions append a concise note to `local/chat-history.md`, referencing the latest snapshot, the observed state, and the next action plan so collaborators can resume without re-running the workflow.

## Artifact tiers

- `artifacts/<snapshot>/commands/`: Just-in-time diagnostic captures per run (journal, dmesg, device stats, `nvidia-smi`, etc.).
- `analysis-summary.md`: Human-readable triage, including resume context, restart history, the three most recent boots, GPU/Xwayland flags, Btrfs counters, and coredump trends.
- `local/chat-history.md`: Lightweight handoff log keyed by ISO timestamps; never committed upstream.

## Signal layers and heuristics

- **Boot triage:** We keep the “last 3 boots” perspective in the `collect_snapshot` defaults. Each new `analysis-summary` references current/prev-1/prev-2 boots so the scoreboard of `wayland`, `compositor`, `storage`, and `Codium` remains visible.
- **Graphics stack:** `analyze_snapshot` tags `Xwayland lost`, `VSYNC` warnings, and now `NVRM: VM: invalid mmap` bursts; persistent logs in `journal-current-warn.txt` are the trigger for proposals such as forcing GDM to X11 or testing `codium --disable-gpu`.
- **Storage counters:** `btrfs device stats /` runs during collection and automatically surfaces `corruption_errs`. When scrub or reinstall actions happen, the script adds context to the summary so the readers know if the errors are legacy or new.
- **Observability:** `nvidia-smi`, `glxinfo`, and `last-reboots` serve as frequent check points; their outputs are referenced in `analysis-summary.md` and in session logs to avoid blind spots.

## Key scripts

- `scripts/run_workflow.sh`: entry point (capture + analyze).
- `scripts/collect_snapshot.sh`: gathers diagnostics, enforces “last 3 reboots,” and writes to `artifacts/<snapshot>`.
- `scripts/analyze_snapshot.sh`: adds heuristics for GPU, Btrfs, and reboot patterns, producing `analysis-summary.md`.
- `scripts/log_session.sh`: appends handoff context to `local/chat-history.md`.
- `scripts/vscodium_gpu.sh`: small helper used during GPU troubleshooting (documented in AGENTS.md for future reference).

## Collaboration posture

- Additive, reversible edits only; evidence files (artifacts) stay local.
- Avoid reorganizing existing logs or manual resets (per AGENTS.md). When new heuristics or detectors are added, keep them small and well-documented inside `scripts/analyze_snapshot.sh`.
- If future contributors want to extend this architecture doc, they can follow the structure in `personal-finance/docs/contributor-architecture-blueprint.md` for layering diagrams, provider pipelines, and testing notes.

## Next steps

1. Draft a diagram once the capture/analysis flow stabilizes and place it under `docs/diagrams/`.
2. Extend `scripts/analyze_snapshot.sh` whenever shared heuristics emerge (per AGENTS instructions).
