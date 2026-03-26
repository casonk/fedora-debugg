# Software Inventory Utility

`scripts/analyze_installed_software.sh` generates a local report of installed
software so you can review what is present, what appears active, and what may
be removable.

## Usage

```bash
./scripts/analyze_installed_software.sh
```

Optional flags:

```bash
./scripts/analyze_installed_software.sh --history-lines 8000
./scripts/analyze_installed_software.sh --output-dir artifacts
./scripts/analyze_installed_software.sh --path-only
```

## Output

Each run creates `artifacts/software-audit-<timestamp>/` and refreshes the
`artifacts/software-latest` symlink.

Important files:

- `software-summary.md`: human-readable overview and short review queues.
- `tables/rpm-packages.tsv`: every installed RPM with install-reason and usage
  hints.
- `tables/applications.tsv`: desktop applications from RPM, Flatpak, and Snap
  sources with activity hints.
- `tables/rpm-removal-review.tsv`: RPM packages that are either DNF-unneeded or
  weakly evidenced.
- `tables/application-removal-review.tsv`: application launchers worth manual
  review.
- `tables/flatpak-runtimes.tsv`: installed Flatpak runtimes.
- `commands/command-status.tsv`: which collection commands succeeded or failed.

## Evidence Sources

The utility is intentionally conservative.

- RPM hints use install reason, `dnf repoquery --leaves`, `dnf repoquery
  --unneeded`, desktop-file ownership, autostart entries, systemd unit files,
  enabled-unit symlinks, and currently running processes.
- Application hints use current processes, autostart presence, recent shell
  history matches, and matching config/cache directories.

## Caveats

- `candidate` means DNF already classifies the RPM as unneeded.
- `review` is only a weak signal. It is not proof an app or package is safe to
  remove.
- Service enablement is inferred from unit symlinks because D-Bus access may be
  unavailable in restricted environments.
- Shell-history hints only see the most recent configured sample of history
  lines and will miss GUI-only launches.
