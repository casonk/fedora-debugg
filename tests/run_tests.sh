#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for test_file in "${SCRIPT_DIR}"/test_*.sh; do
  printf '[test] %s\n' "$(basename "${test_file}")"
  "${test_file}"
done
