#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_exists() {
  local path="$1"
  [ -e "${path}" ] || fail "expected file to exist: ${path}"
}

assert_contains() {
  local path="$1"
  local pattern="$2"
  grep -Fq -- "${pattern}" "${path}" || fail "expected '${pattern}' in ${path}"
}

assert_not_contains() {
  local path="$1"
  local pattern="$2"
  if grep -Fq -- "${pattern}" "${path}"; then
    fail "did not expect '${pattern}' in ${path}"
  fi
}
