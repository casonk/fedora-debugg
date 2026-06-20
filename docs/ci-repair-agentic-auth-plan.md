# `ci-repair-agentic` Authentication Plan

This document captures the next hardening step after the successful
`weekly-blog-agentic` deploy-key cutover.

## Current State

`ci-repair-agentic.service` runs from `traction-control` and performs two
different security-sensitive jobs in one unit:

1. Discovery:
   - enumerate local GitHub repos
   - inspect default branches and local cleanliness with `git`
   - query hosted workflow state with `gh run list`
2. Repair:
   - invoke a full-auto agent with access to the whole portfolio root
   - allow that agent to inspect failing runs, edit repo files, commit, push,
     and verify hosted workflow results

Those two phases do not need the same authority.

## Observed Capability Boundary

From `traction-control/scripts/ci_repair_agentic.sh` and its prompt:

- read-only local git operations:
  - `git status`
  - `git remote get-url origin`
  - `git symbolic-ref`
  - `git show-ref`
- read-only GitHub API operations:
  - `gh auth status`
  - `gh run list`
- full repo write potential delegated to the agent:
  - repo edits in candidate repos
  - `git commit`
  - `git push`
  - follow-up hosted run inspection

The security problem is not the discovery half. It is the shared identity used
by the repair half.

## Why Deploy Keys Alone Do Not Solve This

Deploy keys are strong for single-repo Git transport, but `ci-repair-agentic`
is not a single-repo service.

Limitations:

- deploy keys only cover Git transport, not GitHub API calls such as `gh run
  list`
- one deploy key per repo scales poorly across a portfolio-wide service
- the agent can be pointed at a changing set of candidate repos on each run
- workflow rechecks and richer GitHub metadata still need API auth

Deploy keys remain useful at the repo boundary, but they are not the only auth
layer needed for this service.

## Why Fine-Grained Tokens Help

Fine-grained GitHub tokens are a better fit for the discovery half:

- they can be scoped to selected repositories
- they can be limited to read-only Actions and repository metadata access
- they avoid broad SSH write access just to ask GitHub about workflow state

For discovery, the target shape is:

- selected repos only
- `Actions: Read`
- `Contents: Read` only if needed for metadata or fallback checks
- no write scope

## Why Fine-Grained Tokens Alone Still Fall Short

If the same service continues to repair and push fixes automatically, a single
fine-grained token still has problems:

- it would need write access across many repos
- it may need workflow-related write behavior depending on the fix
- compromise radius would still be broad, just over HTTPS instead of SSH
- the full-auto agent would still hold a multi-repo writer credential

That is better than an interactive personal key, but still not the cleanest
boundary.

## Recommended Redesign

Split `ci-repair-agentic` into separate lanes.

### Lane 1: Discovery

Keep this scheduled and unattended.

- local repo inventory
- `gh run list` and related hosted-run inspection
- read-only fine-grained token
- no Git push capability
- output candidate repo list and run metadata

### Lane 2: Repair

Trigger only when discovery identifies real candidates.

Safer options, ordered from stronger isolation to weaker isolation:

1. Repo-at-a-time repair worker with repo-scoped credential
   - deploy key for Git transport
   - separate API token for hosted run inspection if needed
   - one invocation per repo
2. Dedicated machine identity for multi-repo write
   - not the personal user
   - restricted only to repos the repair worker is allowed to touch
3. Keep broad automation in one service
   - least preferred
   - only acceptable if additional separation is infeasible

## Preferred Near-Term Path

Use a two-phase redesign:

1. Move discovery to a read-only fine-grained token.
2. Stop letting discovery immediately launch a broad multi-repo writer.
3. Replace automatic repair with one of:
   - repo-at-a-time queued repair jobs
   - a dedicated machine identity with explicit repo allowlist

This keeps the current unattended visibility while shrinking write exposure.

## Concrete To-Dos

### Phase A - Capability Inventory

- enumerate exact `gh` commands the discovery path needs
- enumerate exact `git` write operations the repair path performs in practice
- enumerate which repos the service actually touches over a normal month

### Phase B - Read-Only Discovery Auth

- create a fine-grained token for the selected repo set
- move `gh` usage in discovery to that token
- verify `gh run list` and related read-only calls work without SSH write auth

### Phase C - Repair Separation

- stop the discovery unit from directly holding broad Git push authority
- design a repo-at-a-time repair worker contract
- decide whether repair should use:
  - per-repo deploy key plus API token
  - machine user
  - or a future GitHub App if the portfolio grows further

### Phase D - Service Layout

- keep `ci-repair-agentic.service` as discovery only
- add a distinct repair worker entrypoint
- pass candidate repo slug and run metadata explicitly to the repair worker
- keep the repair worker off the personal interactive key path

## Initial Recommendation

Do not try to retrofit deploy keys directly into the existing monolithic
`ci-repair-agentic.service`.

Do this instead:

1. split discovery from repair
2. move discovery to read-only fine-grained token auth
3. design repair as repo-at-a-time execution with narrower credentials

That is the first design that materially improves security without breaking the
service model.
