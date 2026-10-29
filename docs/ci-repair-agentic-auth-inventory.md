# `ci-repair-agentic` Authentication Inventory (Phase A)

Phase A of [the authentication plan](ci-repair-agentic-auth-plan.md): what the
service does today, which identity each step uses, and which credential each
step could use instead. Checked against the live units on 2026-10-29. Repository
names are deliberately absent; the scripts live in `traction-control`.

## What changed since the plan

The plan's split already exists as separate units:

| Unit | State | Runs | Writes to GitHub |
|---|---|---|---|
| `ci-repair-agentic-discovery` (timer, every 2 days) | enabled | `ci_repair_agentic.sh --discovery-only` | no |
| `ci-repair-agentic-repair` (service, no timer) | static, started by hand | `ci_repair_agentic_repair.sh --candidate-file ... --inventory-file ...` | yes, through the agent |
| `ci-repair-agentic` (old monolith, timer) | timer disabled | discovery and repair together | yes |

Discovery no longer launches a writer. The last discovery pass found no
candidates (33 clean, 16 skipped as locally dirty, 1 busy, 0 errors).

## Discovery: exact operations

All read-only, no provider is started.

| Operation | Purpose | Credential today | Minimum credential |
|---|---|---|---|
| `gh auth status` | refuse to run when not logged in | personal `gh` login | none (drop it, or keep as a token check) |
| `git status --porcelain`, `remote get-url origin`, `symbolic-ref`, `show-ref` | local cleanliness and default branch | filesystem | none |
| `gh run list --repo SLUG --branch B --limit N --json databaseId,headSha,status,conclusion,url,workflowName,createdAt,event` | hosted run state | personal `gh` token (scopes `repo`, `read:org`, `gist`) | fine-grained token: `Actions: read`, `Metadata: read`, on the repositories scanned |

The personal token is far broader than this needs: `repo` grants write to every
repository the account can reach, `gist` is unused. Discovery is the clearest
candidate to move first, because it is unattended and runs on a timer.

## Repair: exact operations

The repair worker starts an agent (provider chosen by `auto`: Codex with the
`workspace-write` sandbox, Claude Code with `bypassPermissions`, or Copilot
with `--yolo`) rooted at the control-plane repository with the whole portfolio
root added. The prompt (`config/prompts/ci-repair-agentic.md` in
`traction-control`) tells the agent to:

- inspect the failing runs "with `gh` or equivalent GitHub tooling" (API read)
- edit files in the failing repository (filesystem write)
- run the repository's local gate, then "commit or push" (Git transport over SSH,
  the personal key; the prompt does not require a branch or pull request)
- re-check the hosted run after the push (API read)

Nothing in the script restricts it to the candidate repositories: the sandbox
boundary is the filesystem root of the portfolio, and the push path is the
interactive key, which reaches every repository the account can write. That is
the boundary the plan wants to narrow.

## Mapping operations to credentials

| Step | Needs | Fits |
|---|---|---|
| Discovery run listing | read Actions on many repos | fine-grained token, read-only; the repository list must be refreshed as repositories are added |
| Repair: run inspection | read Actions on one repo | the same read-only token |
| Repair: push to one repository | Git write to one repo | per-repo deploy key (write), selected per invocation |
| Repair: workflow-file changes | `workflows` write | not available to deploy keys; keep these as a pull request from a branch, or make them a manual step |

Deploy keys cover transport only, so the repair step needs the pair
(read-only API token plus a per-repo deploy key). A dedicated machine user would
replace the pair with one identity but gives it write access to every repository
on its allowlist at once, which is the property the split is trying to remove.

## Findings that change the plan

1. **The prompt and the branch rules disagree.** Public repositories reject
   direct pushes to the default branch through the `main-branch-guard`
   ruleset, and private ones use a local hook, yet the prompt says "commit or
   push" with no branch or pull request. A repair push that follows the prompt
   either fails or needs a bypass. The prompt should say branch, pull request,
   merge, and the worker's credential then needs `Pull requests: write` and
   branch push, not default-branch push. That favours a token scoped to pull
   requests over a deploy key on the default branch.
2. **Discovery can move today.** It needs only the read-only token and no
   change to the repair design. This is Phase B and can be done alone.
3. **The repair worker is manual.** The exposure is therefore bounded by how
   often it is started, which is why the order should be discovery token first,
   then repair credentials, and the monolith's timer stays disabled.
4. **The agent sandbox is wider than the credential would be.** Even with a
   narrow credential, a full-auto agent can edit other repositories on disk;
   the per-repo invocation (pass one slug and one working directory, not the
   portfolio root) is the control that matters for that.

## Owner-only steps

Creating a fine-grained token, a deploy key, or a machine user happens in
GitHub's settings and needs the account owner. The repository-side work
(reading the token from the credential store, passing it to `gh` for the
discovery unit only) can then be done without touching the personal login.

## Next actions

- Phase B: create the read-only fine-grained token (owner), store it in the
  credential store, and point only the discovery unit's `GH_TOKEN` at it.
- Phase C: change the repair worker to take one repository per invocation and
  open a pull request instead of pushing the default branch.
- Phase D: delete the disabled monolith unit once the other two have run clean
  for a month.
