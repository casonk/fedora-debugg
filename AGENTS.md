# AGENTS.md

## Project Purpose

This repo exists to debug recurring Fedora workstation crashes using repeatable
evidence collection and triage workflows.

## Operating Rules

- Prefer additive, reversible changes.
- Do not add destructive commands to scripts.
- Keep artifacts local; never commit crash bundles from `artifacts/`.
- Keep a running handoff log in `local/chat-history.md` (git-ignored).
- Handle missing commands and permission-denied cases gracefully.
- Favor plain Bash and standard Fedora tooling.

## Standard Workflow

1. Run `./scripts/run_workflow.sh` (or `sudo ./scripts/run_workflow.sh`).
2. Review `artifacts/latest/analysis-summary.md`.
3. Drill into `artifacts/latest/commands/*.txt` for context.
4. Add new detectors/patterns in `scripts/analyze_snapshot.sh` as new signals
   are discovered.
5. Append a concise session entry via:
   - `./scripts/log_session.sh --snapshot artifacts/latest --summary "<state, actions, next step>"`

## Implementation Priorities

1. Reliable data capture across boots.
2. Fast triage with low false positives.
3. Trend tracking across multiple snapshots.
