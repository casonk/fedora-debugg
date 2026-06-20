#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SERVICE_DIR="${TMP_DIR}/systemd-user"
BLOG_REPO="${TMP_DIR}/casonk.github.io"
TRACTION_REPO="${TMP_DIR}/traction-control"
mkdir -p "${SERVICE_DIR}" "${BLOG_REPO}/scripts" "${TRACTION_REPO}/scripts"

git -C "${BLOG_REPO}" init >/dev/null 2>&1
git -C "${BLOG_REPO}" remote add origin git@github.com:casonk/casonk.github.io.git

git -C "${TRACTION_REPO}" init >/dev/null 2>&1
git -C "${TRACTION_REPO}" remote add origin git@github.com:casonk/traction-control.git

cat >"${BLOG_REPO}/scripts/weekly_blog_agentic.sh" <<'EOF'
#!/usr/bin/env bash
git -C "${REPO_ROOT}" fetch origin
git -C "${REPO_ROOT}" push origin "HEAD:${BRANCH}"
EOF
chmod +x "${BLOG_REPO}/scripts/weekly_blog_agentic.sh"

cat >"${TRACTION_REPO}/scripts/ci_repair_agentic.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${PORTFOLIO_ROOT}"
gh run list --repo casonk/traction-control
EOF
chmod +x "${TRACTION_REPO}/scripts/ci_repair_agentic.sh"

cat >"${SERVICE_DIR}/weekly-blog-agentic.service" <<EOF
[Service]
WorkingDirectory=${BLOG_REPO}
ExecStart=/usr/bin/env bash ${BLOG_REPO}/scripts/weekly_blog_agentic.sh
EOF

cat >"${SERVICE_DIR}/ci-repair-agentic.service" <<EOF
[Service]
WorkingDirectory=${TRACTION_REPO}
ExecStart=${TRACTION_REPO}/scripts/ci_repair_agentic.sh
EOF

OUTPUT_PATH="${TMP_DIR}/phase2.tsv"
"${ROOT_DIR}/scripts/audit_ssh_phase2_candidates.sh" \
  --service-dir "${SERVICE_DIR}" \
  --format tsv \
  >"${OUTPUT_PATH}"

assert_contains "${OUTPUT_PATH}" $'weekly-blog-agentic.service'
assert_contains "${OUTPUT_PATH}" $'casonk/casonk.github.io'
assert_contains "${OUTPUT_PATH}" $'single-repo-write'
assert_contains "${OUTPUT_PATH}" $'\tyes\tone service, one repo, explicit fetch/commit/push path'

assert_contains "${OUTPUT_PATH}" $'ci-repair-agentic.service'
assert_contains "${OUTPUT_PATH}" $'casonk/traction-control'
assert_contains "${OUTPUT_PATH}" $'portfolio-multi-repo'
assert_contains "${OUTPUT_PATH}" $'\tno\tservice script scans or operates across multiple repos'
