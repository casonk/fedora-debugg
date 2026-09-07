# LESSONSLEARNED.md

Tracked durable lessons for `fedora-debugg`.
Unlike `CHATHISTORY.md`, this file should keep only reusable lessons that should change how future sessions work in this repo.

## How To Use

- Read this file after `AGENTS.md` and before `CHATHISTORY.md` when resuming work.
- Add lessons that generalize beyond a single session.
- Keep entries concise and action-oriented.
- Do not use this file for transient status updates or full session logs.

## Lessons

- Host-facing security/tooling tests must account for ambient binaries already
  installed on the workstation. If a test inspects command presence with
  `command -v`, either fully isolate `PATH` or write expectations that remain
  correct when extra baseline tools such as `lynis` or `aide` are installed
  locally.

- Sidecar evidence that must influence `analysis-summary.md` and
  `tachometer-signals.json` should be written inside the snapshot directory
  before those render steps run. Snapshot-local sidecars stay aligned with the
  `artifacts/latest` symlink automatically and avoid cross-run drift from
  separate timestamped artifact trees.

- In this repo, stale snapshot cleanup should preserve crash evidence by moving
  old `artifacts/snapshot-*` directories into ignored repo-local archives with
  restore support. Avoid deletion-based cleanup unless the user explicitly asks
  for evidence to be removed.

- Document the repository around its real execution, curation, or integration flow instead of only the top-level folder list.
- Keep local-only, private, reference-only, or generated boundaries explicit so published or runtime behavior is not confused with offline material or non-committable inputs.
- Re-run repo-appropriate validation after changing generated artifacts, diagrams, workflows, or other CI-facing files so formatting and compatibility issues are caught before push.

- Crash-triage repos should be documented around the evidence loop, not around
  the shell folder list.
- Show the main incident pipeline explicitly: orchestrator, snapshot bundle,
  heuristic summary, remediation helpers, and local handoff.
- Treat broader hardware or software audits as sidecar lanes when they are
  invoked separately from the main crash workflow.
- Capture info-level suspend events separately from warning journals. Repeated
  suspend requests about 900 seconds after GDM starts or the machine resumes
  indicate the greeter's independent idle policy; terminal, SSH, and TTY
  activity does not reset that timer.

- When a `dnf update` soname-bump conflict blocks a library upgrade (a
  dependent package still requires the old `.so.N`), rebuilding the blocked
  package locally needs a specific order or dnf silently "fixes" it wrong:
  - `dnf builddep` on the blocked package's spec will happily downgrade the
    library (and its `-devel`) to whatever version is still compatible with
    the *currently installed* dependent package, instead of erroring - even
    though the top-level `dnf update` correctly refuses and reports the
    conflict. Force-install the target library + `-devel` version first
    (`dnf install --allowerasing lib-X.Y.Z lib-devel-X.Y.Z`, letting it erase
    the blocked package) before running any build-dependency resolution
    against it.
  - `dnf install <path-to-locally-built-rpm>` errors ("Package ... is already
    installed") rather than reinstalling when the rebuilt rpm has the exact
    same NEVRA as what's already on disk. If the previous step actually
    erased the old package, a plain `dnf install` of the new one is not a
    no-op; if it didn't (i.e. the package is still present), that same
    command silently does nothing instead of upgrading the binary.
  - Automated via `scripts/detect_dnf_upgrade_blockers.sh` (detection) and
    `scripts/generate_dnf_rebuild_fix.sh` (generates the correctly-ordered fix
    script) - see the DNF Soname-Bump Upgrade Blockers section of README.md.
