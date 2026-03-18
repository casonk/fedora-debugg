#!/usr/bin/env bash
set -u -o pipefail

ACTION=""
ARGV_PATH=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: ./scripts/vscodium_gpu.sh <enable|disable|status> [options]

Toggle VSCodium GPU acceleration by updating:
  ~/.config/VSCodium/argv.json

Actions:
  enable    Enable GPU acceleration (sets "disable-hardware-acceleration" to false).
  disable   Disable GPU acceleration (sets "disable-hardware-acceleration" to true).
  status    Show interpreted GPU state and raw key value from argv.json.

Options:
  --argv <path>   Override argv.json path.
  --dry-run       Print what would change, do not write.
  --help          Show this help message.
EOF
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

resolve_default_argv_path() {
  local target_user
  local target_home

  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    target_user="${SUDO_USER}"
  else
    target_user="${USER:-}"
  fi

  target_home="$(getent passwd "${target_user}" 2>/dev/null | awk -F: '{print $6}')"
  if [ -z "${target_home}" ]; then
    target_home="${HOME:-/home/${target_user}}"
  fi

  ARGV_PATH="${target_home}/.config/VSCodium/argv.json"
}

read_gpu_flag() {
  local file="$1"

  if [ ! -f "${file}" ]; then
    echo "unset (file missing)"
    return 0
  fi

  if has_cmd jq; then
    jq -r 'if has("disable-hardware-acceleration") then .["disable-hardware-acceleration"] else "unset" end' "${file}" 2>/dev/null || echo "invalid-json"
    return 0
  fi

  if has_cmd python3; then
    python3 - "${file}" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("invalid-json")
    raise SystemExit(0)

if not isinstance(data, dict):
    print("invalid-json")
elif "disable-hardware-acceleration" not in data:
    print("unset")
else:
    print(str(data["disable-hardware-acceleration"]).lower())
PY
    return 0
  fi

  echo "unknown (install jq or python3)"
}

gpu_state_from_raw() {
  local raw_value="$1"
  case "${raw_value}" in
    false)
      echo "enabled"
      ;;
    true)
      echo "disabled"
      ;;
    unset|"unset (file missing)")
      echo "default"
      ;;
    invalid-json)
      echo "unknown (invalid-json)"
      ;;
    *)
      echo "unknown (${raw_value})"
      ;;
  esac
}

print_status() {
  local file="$1"
  local raw_value
  raw_value="$(read_gpu_flag "${file}")"
  echo "argv.json: ${file}"
  echo "gpu-acceleration: $(gpu_state_from_raw "${raw_value}")"
  echo "disable-hardware-acceleration: ${raw_value}"
}

write_updated_json() {
  local input_file="$1"
  local output_file="$2"
  local action="$3"

  if has_cmd jq; then
    if [ "${action}" = "disable" ]; then
      jq '.["disable-hardware-acceleration"] = true' "${input_file}" >"${output_file}"
    else
      jq '.["disable-hardware-acceleration"] = false' "${input_file}" >"${output_file}"
    fi
    return 0
  fi

  if has_cmd python3; then
    python3 - "${input_file}" "${output_file}" "${action}" <<'PY'
import json
import sys

in_path, out_path, action = sys.argv[1], sys.argv[2], sys.argv[3]
with open(in_path, "r", encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, dict):
    raise SystemExit("argv.json must contain a JSON object")
data["disable-hardware-acceleration"] = (action == "disable")
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
    return 0
  fi

  echo "Error: jq or python3 is required to edit JSON safely." >&2
  return 1
}

backup_if_exists() {
  local file="$1"
  if [ -f "${file}" ]; then
    local backup="${file}.bak-$(date +%Y%m%d-%H%M%S-%N)"
    cp "${file}" "${backup}"
    echo "Backup: ${backup}"
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    enable|disable|status)
      if [ -n "${ACTION}" ]; then
        echo "Only one action can be provided." >&2
        usage >&2
        exit 1
      fi
      ACTION="$1"
      shift
      ;;
    --argv)
      if [ $# -lt 2 ]; then
        echo "Missing value for --argv" >&2
        exit 1
      fi
      ARGV_PATH="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "${ACTION}" ]; then
  usage >&2
  exit 1
fi

if [ -z "${ARGV_PATH}" ]; then
  resolve_default_argv_path
fi

case "${ARGV_PATH}" in
  /*) ;;
  *) ARGV_PATH="$(pwd)/${ARGV_PATH}" ;;
esac

if [ "${ACTION}" = "status" ]; then
  print_status "${ARGV_PATH}"
  exit 0
fi

mkdir -p "$(dirname "${ARGV_PATH}")"

tmp_input="$(mktemp "${TMPDIR:-/tmp}/vscodium-argv-input-XXXXXX")"
tmp_output="$(mktemp "${TMPDIR:-/tmp}/vscodium-argv-output-XXXXXX")"
cleanup() {
  rm -f "${tmp_input}" "${tmp_output}"
}
trap cleanup EXIT

if [ -f "${ARGV_PATH}" ] && [ -s "${ARGV_PATH}" ]; then
  cp "${ARGV_PATH}" "${tmp_input}"
else
  printf '{}\n' >"${tmp_input}"
fi

if ! write_updated_json "${tmp_input}" "${tmp_output}" "${ACTION}"; then
  exit 1
fi

if [ "${DRY_RUN}" -eq 1 ]; then
  raw_result="$(read_gpu_flag "${tmp_output}")"
  echo "Dry run only."
  echo "argv.json: ${ARGV_PATH}"
  echo "Action: ${ACTION}"
  echo "Resulting gpu-acceleration: $(gpu_state_from_raw "${raw_result}")"
  echo "Resulting disable-hardware-acceleration: ${raw_result}"
  exit 0
fi

backup_if_exists "${ARGV_PATH}"
mv "${tmp_output}" "${ARGV_PATH}"

raw_result="$(read_gpu_flag "${ARGV_PATH}")"
echo "Updated: ${ARGV_PATH}"
echo "gpu-acceleration: $(gpu_state_from_raw "${raw_result}")"
echo "disable-hardware-acceleration: ${raw_result}"
