# Changelog

All notable changes to `fedora-debugg` are documented here.

## Unreleased

- Added automatic host updates and scheduled reboots (`scripts/host_update.py`, `scripts/install_host_update.sh`, `config/clockwork/host-update-notify.toml.template`, `scripts/install_host_update_notify.sh`): a daily root timer applies dnf security updates (everything on Sundays) after the soname-blocker pre-check, a night-time timer reboots only when an update needs it and the host is idle (with a cancellable grace period, a hold file and a 7-day override), and a user-level job alerts through shock-relay once per condition. Reboot safety accounts for ignition's PCR 7 TPM unlock; firmware is never applied automatically.
- Added the `ci-repair-agentic` authentication inventory (Phase A): exact discovery and repair operations mapped to the least-privilege credential for each.
- Added the portfolio-standard governance, continuity, and contributor baseline files.
