# AGENTS.md

## Project Purpose

This repo exists to debug recurring Fedora workstation crashes using repeatable
evidence collection and triage workflows.

## Operating Rules

- Prefer additive, reversible changes.
- Do not add destructive commands to scripts.
- Keep artifacts local; never commit crash bundles from `artifacts/`.
- Keep a running handoff log in repo-root `CHATHISTORY.md` (git-ignored).
- Do not use `local/` as the default handoff location; keep the concise resume summary in `CHATHISTORY.md`.
- Handle missing commands and permission-denied cases gracefully.
- Favor plain Bash and standard Fedora tooling.
- Periodically clean up or terminate background terminals and long-running ad hoc
  commands once they are no longer needed.

## Standard Workflow

1. Run `./scripts/run_workflow.sh` (or `sudo ./scripts/run_workflow.sh`).
2. Review `artifacts/latest/analysis-summary.md`.
3. Drill into `artifacts/latest/commands/*.txt` for context.
4. Add new detectors/patterns in `scripts/analyze_snapshot.sh` as new signals
   are discovered.
   - Keep `Runtime/Profile/Wayland-GPU` heuristics current for Electron/Codium
     crash loops.
5. Append a concise session entry via:
   - `./scripts/log_session.sh --snapshot artifacts/latest --summary "<state, actions, next step>"`

## Implementation Priorities

1. Reliable data capture across boots.
2. Fast triage with low false positives.
3. Trend tracking across multiple snapshots.

## Agent Memory

Use `./LESSONSLEARNED.md` as the tracked durable lessons file for this repo.
Use `./CHATHISTORY.md` as the standard local handoff file for this repo.

- `LESSONSLEARNED.md` is tracked and should capture only reusable lessons.
- `CHATHISTORY.md` is local-only, gitignored, and should capture transient handoff context.
- Read `LESSONSLEARNED.md` and `CHATHISTORY.md` after `AGENTS.md` when resuming work.
- Add durable lessons to `LESSONSLEARNED.md` when they should influence future sessions.
- Keep transient entries concise: objective, latest diagnosis, blockers, and next step.
- `scripts/log_session.sh` appends the incident timeline to `CHATHISTORY.md`.
