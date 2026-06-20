# Phase 2 Runbook: `weekly-blog-agentic`

This is the recommended first live Phase 2 cutover target.

Why this service:

- one systemd user service
- one local repo
- one GitHub remote
- one explicit `git push` path

It is a much better first isolation boundary than portfolio-wide maintenance
services that can touch many repos.

## Target Boundary

- Service: `weekly-blog-agentic.service`
- Repo: `casonk/casonk.github.io`
- Access needed: write access to that repo only
- Access not needed: broad write access across the rest of GitHub

## Desired End State

- The service no longer depends on the personal interactive GitHub key.
- The service uses a dedicated deploy key with write access only to
  `casonk/casonk.github.io`.
- The service gets its own SSH config path through `GIT_SSH_COMMAND`.

## Suggested Key Layout

- Private key: `~/.ssh/id_ed25519_casonk_github_io_weekly_blog`
- Public key: `~/.ssh/id_ed25519_casonk_github_io_weekly_blog.pub`
- Service SSH config: `~/.config/casonk.github.io/ssh/config`
- Service drop-in:
  `~/.config/systemd/user/weekly-blog-agentic.service.d/10-ssh-identity.conf`

## Cutover Steps

### 1. Generate the dedicated deploy key

```bash
ssh-keygen -t ed25519 \
  -f ~/.ssh/id_ed25519_casonk_github_io_weekly_blog \
  -C "weekly-blog-agentic@desk casonk.github.io deploy"
chmod 600 ~/.ssh/id_ed25519_casonk_github_io_weekly_blog
chmod 644 ~/.ssh/id_ed25519_casonk_github_io_weekly_blog.pub
```

### 2. Register the public key as a write-capable deploy key

```bash
gh repo deploy-key add ~/.ssh/id_ed25519_casonk_github_io_weekly_blog.pub \
  --repo casonk/casonk.github.io \
  --allow-write \
  --title "weekly-blog-agentic@desk"
```

### 3. Install the service-specific SSH config

Use the example at:

- `config/security/ssh/weekly-blog-agentic.config.example`

Install it as:

```bash
mkdir -p ~/.config/casonk.github.io/ssh
cp /mnt/4tb-m2/git/util-repos/fedora-debugg/config/security/ssh/weekly-blog-agentic.config.example \
  ~/.config/casonk.github.io/ssh/config
chmod 600 ~/.config/casonk.github.io/ssh/config
```

The config intentionally sets `IdentityAgent none` so the service cannot fall
back to the interactive user agent.

### 4. Install the systemd drop-in

Use the example at:

- `config/security/systemd/weekly-blog-agentic.service.d/10-ssh-identity.conf.example`

Install it as:

```bash
mkdir -p ~/.config/systemd/user/weekly-blog-agentic.service.d
cp /mnt/4tb-m2/git/util-repos/fedora-debugg/config/security/systemd/weekly-blog-agentic.service.d/10-ssh-identity.conf.example \
  ~/.config/systemd/user/weekly-blog-agentic.service.d/10-ssh-identity.conf
systemctl --user daemon-reload
```

### 5. Verify Git over the dedicated config

```bash
GIT_SSH_COMMAND='ssh -F /home/user/.config/casonk.github.io/ssh/config' \
  git -C /mnt/4tb-m2/git/doc-repos/casonk.github.io fetch origin
```

### 6. Verify write access without publishing a post

First validate the key identity path:

```bash
ssh -F /home/user/.config/casonk.github.io/ssh/config -T git@github.com
```

Expected result:

```text
Hi casonk! You've successfully authenticated, but GitHub does not provide shell access.
```

Then run the service logic without push:

```bash
WEEKLY_BLOG_AGENTIC_PUSH=0 \
GIT_SSH_COMMAND='ssh -F /home/user/.config/casonk.github.io/ssh/config' \
/usr/bin/env bash /mnt/4tb-m2/git/doc-repos/casonk.github.io/scripts/weekly_blog_agentic.sh --no-push
```

### 7. Verify the real service path

```bash
systemctl --user start weekly-blog-agentic.service
journalctl --user -u weekly-blog-agentic.service --no-pager -n 200
```

## Rollback

If the dedicated path fails:

- remove the drop-in
- reload the user daemon
- keep the deploy key disabled or delete it from GitHub
- leave the personal key path untouched until the dedicated path is proven

## Success Criteria

- `git fetch` works through the service-specific SSH config.
- `ssh -T git@github.com` works through the service-specific SSH config.
- `weekly_blog_agentic.sh --no-push` succeeds with the service-specific SSH
  config.
- `weekly-blog-agentic.service` runs without falling back to the personal key.
- only `casonk/casonk.github.io` is reachable with the dedicated key.
