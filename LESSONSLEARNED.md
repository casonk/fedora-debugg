# LESSONSLEARNED.md

Tracked durable lessons for `fedora-debugg`.
Unlike `CHATHISTORY.md`, this file should keep only reusable lessons that should change how future sessions work in this repo.

## How To Use

- Read this file after `AGENTS.md` and before `CHATHISTORY.md` when resuming work.
- Add lessons that generalize beyond a single session.
- Keep entries concise and action-oriented.
- Do not use this file for transient status updates or full session logs.

## Lessons

- Crash-triage repos should be documented around the evidence loop, not around
  the shell folder list.
- Show the main incident pipeline explicitly: orchestrator, snapshot bundle,
  heuristic summary, remediation helpers, and local handoff.
- Treat broader hardware or software audits as sidecar lanes when they are
  invoked separately from the main crash workflow.
