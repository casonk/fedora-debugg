# Contributor Architecture Blueprint

This document is the concise implementation map for `fedora-debugg`. The repo's
real architecture is a repeatable crash-triage workflow plus sidecar audit lanes
for storage/hardware and installed-software inspection.

For the longer narrative, see `docs/architecture.md`.

## Core Runtime Lane

1. Orchestration layer (`scripts/run_workflow.sh`)
   - Stable capture-plus-analyze entrypoint.
   - Validates that collection returned a real snapshot path before continuing.
2. Evidence collection layer (`scripts/collect_snapshot.sh`)
   - Writes `artifacts/snapshot-<timestamp>/commands/` with reboot logs,
     `journalctl`, `dmesg`, package state, session metadata, GPU info, and
     VSCodium config.
   - Refreshes `artifacts/latest` for follow-on analysis and manual review.
3. Triage synthesis layer (`scripts/analyze_snapshot.sh`)
   - Converts raw command captures into `analysis-summary.md`.
   - Houses the reusable heuristics for boot windows, GPU/Wayland failures,
     VSCodium runtime/profile issues, Btrfs counters, and coredumps.
4. Remediation helper layer (`scripts/vscodium_gpu.sh`)
   - Operational branch used when the summary points at the
     runtime/profile/Wayland-GPU cluster.
   - Safely inspects or edits `argv.json` with backups.
5. Continuity layer (`scripts/log_session.sh`, repo-root `CHATHISTORY.md`)
   - Persists the concise local handoff after a triage run or manual follow-up.

## Sidecar Audit Lanes

- `scripts/analyze_storage_hardware.sh`
  - On-demand hardware and storage audit path.
  - Produces a report separate from the main incident summary.
- `scripts/analyze_installed_software.sh`
  - On-demand software inventory and runtime audit path.
  - Useful when the incident requires package-surface comparison rather than
    another snapshot pass.

## Key Data Surfaces

- `artifacts/snapshot-<timestamp>/commands/`
- `artifacts/latest`
- `artifacts/latest/analysis-summary.md`
- repo-root `CHATHISTORY.md`

## Validation Surface

- `./tests/run_tests.sh`
- `shellcheck $(find . -name '*.sh' -not -path './.git/*')`
- `.github/workflows/ci.yml`
