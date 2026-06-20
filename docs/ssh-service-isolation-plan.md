# SSH Service Isolation Plan

This document captures the recommended hardening path for SSH identities on the
Fedora workstation. The goal is to reduce blast radius across interactive work,
automation, and long-running services without making the host impossible to
operate.

## Security Goals

- Keep interactive shell access separate from automation and daemon access.
- Limit each private key to one trust domain, repo, or service role when
  practical.
- Route SSH usage through explicit config instead of ad hoc shell state.
- Avoid storing passphrases in shell startup files, repo files, or plain-text
  service environment files.
- Make key rotation and revocation localized instead of disruptive.

## Preferred Model

Use separation by identity and process boundary, not by Unix group alone.

- Interactive work: one personal key per platform or trust domain.
- Automation: one key per service or repo where platform support exists.
- Daemons: separate OS user per long-running service, with service-owned key
  material and explicit unit-level routing.
- Agent access: one managed user socket for interactive use, optional
  service-specific sockets only where separation is worth the complexity.

Unix groups can help with file readability on disk, but they do not provide
strong isolation once a process can talk to an agent socket. The stronger
control points are:

- private-key file ownership and mode
- which OS user can read the key
- which process can reach the agent socket
- host-side restrictions such as deploy keys and forced commands

## Recommended Identity Layout

Suggested baseline naming:

- `~/.ssh/id_ed25519_github_personal`
- `~/.ssh/id_ed25519_gitlab_personal`
- `~/.ssh/id_ed25519_repo_<repo-name>_deploy`
- `/var/lib/<service>/.ssh/id_ed25519_<service>`

Suggested trust boundaries:

- personal Git hosting
- personal admin access to private hosts
- repo-scoped automation
- service-to-service access
- emergency or break-glass access, kept offline where possible

## Routing Rules

Route identities explicitly.

- Global SSH client config should pin the managed agent socket and default
  identity policy.
- Repo-local overrides should use `core.sshCommand` only when a repo needs a
  non-default socket or key.
- User services should set `Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket`
  only when they are intentionally using the interactive user agent.
- System or persistent automation services should prefer a dedicated service
  account and `IdentityFile` over the interactive user key.

## Hardening Rules

- Keep private keys at mode `0600` and directories at `0700`.
- Keep the interactive agent socket under `/run/user/<uid>/`.
- Do not export passphrases from shell init files.
- Do not share one private key across personal shells, GitHub automation, and
  long-running services.
- Prefer GitHub deploy keys or machine users for repo automation instead of
  reusing the personal interactive key.
- Use `ssh-add -t <duration>` for interactive sessions where automatic expiry is
  acceptable.
- Remove stale backup copies of private keys immediately after successful
  rotation.

## To-Do Plan

### Phase 0 - Inventory

- Enumerate current private keys, their passphrase state, and where each is
  used.
- Enumerate current SSH consumers: interactive shells, tmux sessions, Git
  repos, timers, user services, and system services.
- Record which services currently depend on the personal GitHub key.

### Phase 1 - Interactive Baseline

- Keep the systemd-managed user `ssh-agent.socket` as the only interactive
  agent.
- Pin `IdentityAgent /run/user/1000/ssh-agent.socket` in SSH client config.
- Move the interactive GitHub key to a role-specific filename rather than the
  generic `id_ed25519`.
- Verify fresh-login behavior in a new shell, in tmux, and through Git.

### Phase 2 - Split Automation

- Identify every repo or tool that currently reuses the personal key.
- Create a dedicated automation or deploy key for the highest-risk service
  first.
- Register that key as a deploy key or machine-user key with the narrowest
  permissions available.
- Route only that repo or service to the new key and verify normal operation.

### Phase 3 - Service Accounts

- For long-running jobs, create a dedicated OS user per service class.
- Move service-owned private keys under the service account home or state
  directory.
- Keep service unit ownership and file modes restrictive.
- Remove those services from the interactive user key path entirely.

### Phase 4 - Host-Side Restrictions

- Use repo-scoped deploy keys where the platform supports them.
- Use forced commands and source restrictions for host SSH access where
  practical.
- Remove any unnecessary write-capable key from broad platform access.

### Phase 5 - Rotation and Audit

- Define a rotation cadence for personal, deploy, and service keys.
- Add a simple audit checklist for file modes, socket paths, and stale keys.
- Track which key fingerprints map to which service and access scope.

### Phase 6 - Decommission Shared Access

- Remove any service still using the personal interactive key.
- Revoke old shared keys from GitHub and other hosts.
- Confirm each remaining key has one clear owner and one clear purpose.

## Slow Integration Path

Start with the smallest safe step and verify each boundary before moving on.

1. Establish explicit SSH routing for interactive use.
2. Pick one non-interactive repo or service and give it a dedicated key.
3. Test only that path.
4. Expand to the next service after the first isolation path is stable.

Avoid rotating several services at once. The risk is not just breakage; it is
also losing clarity about which identity is actually being exercised.

## First Integration Target

The first practical target should be the highest-value automation path that does
not need broad personal account access. Good candidates:

- `weekly-blog-agentic.service` for `casonk/casonk.github.io`
- a repo-specific GitHub deploy key
- a single background sync or mirror job
- a single user service that currently shells out to Git over SSH

Do not start by splitting every interactive repo. Start by removing one
automation path from the personal key.

## Verification Checklist

- `ssh -G <host>` resolves the intended `identityagent` and `identityfile`.
- `git config --get core.sshCommand` is set only where intentionally required.
- `ssh-add -l` on the interactive socket lists only intended interactive keys.
- service units do not rely on shell startup files for SSH routing.
- GitHub or host access succeeds with the new dedicated key and fails without
  it.
- old shared-key access is removed after the replacement path is verified.

## Repo-Local Templates

See:

- `config/security/ssh/config.example`
- `config/security/systemd/service-ssh-identity-example.service`

These are templates only. They are not live system configuration.
