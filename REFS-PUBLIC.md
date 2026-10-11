# REFS-PUBLIC.md - Public References

> Record external public repositories, datasets, documentation, APIs, or other
> public resources that this repository utilizes or depends on.
> This file is tracked and intentionally kept free of private or local-only details.

## Public Repositories

- No fixed external code repository is the main upstream; the repo inspects local Fedora workstation state.

## Public Datasets and APIs

- No standing public data APIs are required; evidence is collected directly from the local host after crashes or reboots.

## Documentation and Specifications

- https://docs.fedoraproject.org/en-US/quick-docs/ - Fedora operational reference for workstation tooling and packaging behavior
- https://www.freedesktop.org/software/systemd/man/latest/journalctl.html - journalctl reference for evidence collection
- https://www.freedesktop.org/software/systemd/man/latest/systemd-coredump.html - coredump workflow reference
- https://docs.clamav.net/ - ClamAV scanner and signature-update reference used by the security scan workflow
- https://aide.github.io/ - AIDE file-integrity database and check reference
- https://cisofy.com/documentation/lynis/ - Lynis system-audit reference used by the baseline scanner
- https://www.open-scap.org/resources/documentation/ - OpenSCAP reference used by the SCAP baseline scan
- https://github.com/linux-audit/audit-documentation - Linux Audit and auditd reference used by the audit evidence collector

## Notes

- Crash signatures and host evidence stay local. This tracked file only records the public OS and tooling documentation the workflow leans on.
