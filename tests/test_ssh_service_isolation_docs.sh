#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

PLAN_DOC="${ROOT_DIR}/docs/ssh-service-isolation-plan.md"
SSH_TEMPLATE="${ROOT_DIR}/config/security/ssh/config.example"
SYSTEMD_TEMPLATE="${ROOT_DIR}/config/security/systemd/service-ssh-identity-example.service"
WEEKLY_BLOG_DOC="${ROOT_DIR}/docs/ssh-phase2-weekly-blog-agentic.md"
WEEKLY_BLOG_SSH_TEMPLATE="${ROOT_DIR}/config/security/ssh/weekly-blog-agentic.config.example"
WEEKLY_BLOG_DROPIN="${ROOT_DIR}/config/security/systemd/weekly-blog-agentic.service.d/10-ssh-identity.conf.example"
CI_REPAIR_DOC="${ROOT_DIR}/docs/ci-repair-agentic-auth-plan.md"

assert_file_exists "${PLAN_DOC}"
assert_file_exists "${SSH_TEMPLATE}"
assert_file_exists "${SYSTEMD_TEMPLATE}"
assert_file_exists "${WEEKLY_BLOG_DOC}"
assert_file_exists "${WEEKLY_BLOG_SSH_TEMPLATE}"
assert_file_exists "${WEEKLY_BLOG_DROPIN}"
assert_file_exists "${CI_REPAIR_DOC}"

assert_contains "${PLAN_DOC}" "## To-Do Plan"
assert_contains "${PLAN_DOC}" "### Phase 2 - Split Automation"
assert_contains "${PLAN_DOC}" "### Phase 3 - Service Accounts"
assert_contains "${PLAN_DOC}" "### Phase 5 - Rotation and Audit"
assert_contains "${PLAN_DOC}" "## First Integration Target"
assert_contains "${PLAN_DOC}" "## Verification Checklist"
assert_contains "${PLAN_DOC}" "weekly-blog-agentic.service"

assert_contains "${SSH_TEMPLATE}" "IdentityAgent /run/user/1000/ssh-agent.socket"
assert_contains "${SSH_TEMPLATE}" "IdentityFile ~/.ssh/id_ed25519_github_personal"
assert_contains "${SSH_TEMPLATE}" "IdentitiesOnly yes"

assert_contains "${SYSTEMD_TEMPLATE}" "User=svc-example"
assert_contains "${SYSTEMD_TEMPLATE}" 'Environment="GIT_SSH_COMMAND=ssh -F /var/lib/svc-example/.ssh/config"'
assert_contains "${SYSTEMD_TEMPLATE}" "NoNewPrivileges=yes"
assert_contains "${SYSTEMD_TEMPLATE}" "ProtectSystem=strict"

assert_contains "${WEEKLY_BLOG_DOC}" "weekly-blog-agentic.service"
assert_contains "${WEEKLY_BLOG_DOC}" "gh repo deploy-key add"
assert_contains "${WEEKLY_BLOG_DOC}" "WEEKLY_BLOG_AGENTIC_PUSH=0"
assert_contains "${CI_REPAIR_DOC}" "Move discovery to a read-only fine-grained token."
assert_contains "${CI_REPAIR_DOC}" "Do not try to retrofit deploy keys directly into the existing monolithic"
assert_contains "${CI_REPAIR_DOC}" "split discovery from repair"

assert_contains "${WEEKLY_BLOG_SSH_TEMPLATE}" "IdentityFile /home/user/.ssh/id_ed25519_casonk_github_io_weekly_blog"
assert_contains "${WEEKLY_BLOG_SSH_TEMPLATE}" "IdentityAgent none"
assert_contains "${WEEKLY_BLOG_SSH_TEMPLATE}" "IdentitiesOnly yes"

assert_contains "${WEEKLY_BLOG_DROPIN}" 'Environment="GIT_SSH_COMMAND=ssh -F /home/user/.config/casonk.github.io/ssh/config"'
