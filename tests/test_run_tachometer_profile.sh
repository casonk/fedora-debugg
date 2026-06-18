#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FAKE_BIN="${TMP_DIR}/bin"
mkdir -p "${FAKE_BIN}"
cat >"${FAKE_BIN}/tachometer" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${TACHOMETER_ARGS_FILE}"
EOF
chmod +x "${FAKE_BIN}/tachometer"

run_case() {
  local expected="$1"
  shift
  TACHOMETER_ARGS_FILE="${TMP_DIR}/args.txt" PATH="${FAKE_BIN}:${PATH}" \
    "${ROOT_DIR}/scripts/run_tachometer_profile.sh" "$@" >/dev/null
  assert_contains "${TMP_DIR}/args.txt" "${expected}"
}

run_case "snapshot --manifest ${ROOT_DIR}/config/tachometer/profile.toml" snapshot
run_case "summarize --manifest ${ROOT_DIR}/config/tachometer/profile.toml" summarize
run_case "host-snapshot --manifest ${ROOT_DIR}/config/tachometer/profile.toml" host-snapshot
run_case "host-summarize --manifest ${ROOT_DIR}/config/tachometer/profile.toml" host-summarize
run_case "agent-utilization --manifest ${ROOT_DIR}/config/tachometer/profile.toml" agent-utilization
run_case "run --manifest ${ROOT_DIR}/config/tachometer/profile.toml -- echo ok" run -- echo ok

if "${ROOT_DIR}/scripts/run_tachometer_profile.sh" invalid >/dev/null 2>"${TMP_DIR}/usage.txt"; then
  fail "invalid subcommand unexpectedly succeeded"
fi
assert_contains "${TMP_DIR}/usage.txt" "host-snapshot"
