# Contributor Architecture Blueprint

This document is a concise map of how `fedora-debugg` captures crash evidence, analyzes snapshots, and records local triage continuity.

For a deeper narrative, also see `docs/architecture.md`.

## High-Level Layers

1. Workflow orchestration layer (`scripts/run_workflow.sh`)
   - Coordinates the standard evidence-collection and analysis flow.
   - The top-level workflow should remain safe to re-run on the same host.
2. Snapshot analysis layer (`scripts/analyze_snapshot.sh` and related analyzers)
   - Parses collected evidence into triage-friendly findings and summary output.
   - New heuristics should be additive and tuned for low false positives.
3. Reporting layer (`artifacts/latest/analysis-summary.md`, command logs)
   - Collected outputs stay local and should never be committed.
   - The summary file is the fastest entry point for understanding the latest run.
4. Session-memory layer (`scripts/log_session.sh`, repo-root `CHATHISTORY.md`)
   - Logs the concise local handoff state after a run or manual investigation.
   - This repo intentionally keeps short operational continuity at the root instead of under `local/`.

## Key Entry Points

- `./scripts/run_workflow.sh`
- `./scripts/log_session.sh --snapshot artifacts/latest --summary "..."`
- `artifacts/latest/analysis-summary.md`
- `.github/workflows/ci.yml`

## Validation

```bash
./tests/run_tests.sh
shellcheck $(find . -name '*.sh' -not -path './.git/*')
```
