#!/usr/bin/env bash
# Inventory GitHub-facing user services and suggest a narrow first Phase 2 SSH
# isolation target.

set -euo pipefail

SERVICE_DIR="${HOME}/.config/systemd/user"
OUTPUT_FORMAT="tsv"

usage() {
  cat <<EOF
Usage: audit_ssh_phase2_candidates.sh [options]

Scan user systemd services, map them to local git repos, inspect their entrypoint
scripts for GitHub/write behavior, and recommend narrow first-cut Phase 2 SSH
isolation candidates.

Options:
  --service-dir PATH   Override the user systemd service directory.
  --format FORMAT      Output format: tsv or markdown (default: tsv).
  --help               Show this help.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

trim_line() {
  printf '%s' "$1" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

read_unit_value() {
  local file="$1"
  local key="$2"
  local raw
  raw="$(sed -n "s/^${key}=//p" "${file}" | head -n 1)"
  trim_line "${raw}"
}

parse_github_slug() {
  local remote_url="$1"

  case "${remote_url}" in
    git@github.com:*)
      remote_url="${remote_url#git@github.com:}"
      ;;
    https://github.com/*)
      remote_url="${remote_url#https://github.com/}"
      ;;
    ssh://git@github.com/*)
      remote_url="${remote_url#ssh://git@github.com/}"
      ;;
    *)
      return 1
      ;;
  esac

  remote_url="${remote_url%.git}"
  [ -n "${remote_url}" ] || return 1
  printf '%s\n' "${remote_url}"
}

entrypoint_path() {
  local exec_start="$1"
  local token

  for token in $(printf '%s\n' "${exec_start}" | tr ' ' '\n'); do
    token="$(trim_line "${token}")"
    case "${token}" in
      /*)
        if [ -f "${token}" ]; then
          printf '%s\n' "${token}"
          return 0
        fi
        ;;
    esac
  done

  return 1
}

classify_service() {
  local service_name="$1"
  local script_path="$2"
  local repo_slug="$3"
  local class="repo-local-read"
  local recommended="no"
  local reason="repo-local service with no explicit GitHub write markers"

  if [ -z "${repo_slug}" ]; then
    printf 'non-github\tno\tno GitHub origin remote\n'
    return 0
  fi

  if [ -n "${script_path}" ] && grep -Eq 'git( -C [^[:space:]]+)? push ' "${script_path}"; then
    class="single-repo-write"
    recommended="yes"
    reason="single GitHub repo service with explicit git push path"
  fi

  if [ -n "${script_path}" ] && grep -Fq 'PORTFOLIO_ROOT' "${script_path}"; then
    class="portfolio-multi-repo"
    recommended="no"
    reason="service script scans or operates across multiple repos"
  fi

  if [ -n "${script_path}" ] && grep -Eq 'gh run|gh repo|gh pr|gh workflow' "${script_path}"; then
    if [ "${class}" = "repo-local-read" ]; then
      class="github-api-read"
      reason="service uses GitHub API or CLI but no explicit repo push path"
    fi
  fi

  if [ "${service_name}" = "weekly-blog-agentic.service" ]; then
    class="single-repo-write"
    recommended="yes"
    reason="one service, one repo, explicit fetch/commit/push path"
  fi

  printf '%s\t%s\t%s\n' "${class}" "${recommended}" "${reason}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --service-dir)
      SERVICE_DIR="$2"
      shift 2
      ;;
    --format)
      OUTPUT_FORMAT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[ -d "${SERVICE_DIR}" ] || fail "service directory does not exist: ${SERVICE_DIR}"
case "${OUTPUT_FORMAT}" in
  tsv|markdown)
    ;;
  *)
    fail "--format must be tsv or markdown"
    ;;
esac

if [ "${OUTPUT_FORMAT}" = "markdown" ]; then
  printf '| service | repo | repo_slug | class | recommended | reason |\n'
  printf '|---|---|---|---|---|---|\n'
else
  printf 'service\trepo\trepo_slug\tclass\trecommended\treason\n'
fi

for service_file in "${SERVICE_DIR}"/*.service; do
  [ -f "${service_file}" ] || continue

  service_name="$(basename "${service_file}")"
  working_directory="$(read_unit_value "${service_file}" "WorkingDirectory")"
  exec_start="$(read_unit_value "${service_file}" "ExecStart")"
  repo_root=""
  repo_slug=""
  origin_url=""
  script_path=""

  if [ -n "${working_directory}" ] && git -C "${working_directory}" rev-parse --show-toplevel >/dev/null 2>&1; then
    repo_root="$(git -C "${working_directory}" rev-parse --show-toplevel 2>/dev/null || true)"
    origin_url="$(git -C "${repo_root}" remote get-url origin 2>/dev/null || true)"
    repo_slug="$(parse_github_slug "${origin_url}" 2>/dev/null || true)"
  fi

  script_path="$(entrypoint_path "${exec_start}" 2>/dev/null || true)"
  IFS=$'\t' read -r class recommended reason < <(
    classify_service "${service_name}" "${script_path}" "${repo_slug}"
  )

  if [ "${OUTPUT_FORMAT}" = "markdown" ]; then
    printf '| %s | %s | %s | %s | %s | %s |\n' \
      "${service_name}" \
      "${repo_root:-"-"}" \
      "${repo_slug:-"-"}" \
      "${class}" \
      "${recommended}" \
      "${reason}"
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${service_name}" \
      "${repo_root:-"-"}" \
      "${repo_slug:-"-"}" \
      "${class}" \
      "${recommended}" \
      "${reason}"
  fi
done | sort
