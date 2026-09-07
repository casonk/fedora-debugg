#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_FILE=""
DNF_BIN="dnf"
RPM_BIN="rpm"

usage() {
  cat <<'EOF'
Usage: ./scripts/detect_dnf_upgrade_blockers.sh [--output <file>] [--dnf <path>] [--rpm <path>]

Non-destructively probes `dnf update` for the soname-bump conflict class:
"installed package X requires Y, but none of the providers can be
installed" - i.e. a library update is blocked because a dependent package
has not been rebuilt against the new soname yet (see e.g. ttyd vs
libwebsockets after a 4.4 -> 4.5 bump).

Runs `dnf update --refresh --assumeno`, so it never installs, removes, or
downgrades anything. Safe to run at any time, including via cron/timer.

For each blocked package/capability pair found, reports the library
package currently providing the capability and suggests running
`./scripts/generate_dnf_rebuild_fix.sh <package>` to build the fix.

Options:
  --output <file>   Also write the markdown report to this file.
  --dnf <path>      Override the dnf binary (used by tests).
  --rpm <path>      Override the rpm binary (used by tests).
  --help            Show this help message.

Exit status: 0 if no blockers were found, 1 if one or more were found.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --output)
      [ $# -ge 2 ] || { echo "Missing value for --output" >&2; exit 1; }
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --dnf)
      [ $# -ge 2 ] || { echo "Missing value for --dnf" >&2; exit 1; }
      DNF_BIN="$2"
      shift 2
      ;;
    --rpm)
      [ $# -ge 2 ] || { echo "Missing value for --rpm" >&2; exit 1; }
      RPM_BIN="$2"
      shift 2
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

dnf_output="$("${DNF_BIN}" update --refresh --assumeno 2>&1)"
dnf_status=$?

mapfile -t problem_lines < <(
  printf '%s\n' "${dnf_output}" \
    | grep -E 'installed package [^ ]+ requires .* but none of the providers can be installed' \
    || true
)

report="$(mktemp)"
{
  printf '# DNF Upgrade Blocker Report\n\n'
  printf 'Generated: %s\n\n' "$(date --iso-8601=seconds)"

  if [ "${#problem_lines[@]}" -eq 0 ]; then
    printf 'No soname-bump upgrade blockers detected.\n'
    if [ "${dnf_status}" -ne 0 ]; then
      printf '\n`dnf update --refresh --assumeno` exited non-zero (%s) for an unrelated reason; raw output:\n\n```\n%s\n```\n' \
        "${dnf_status}" "${dnf_output}"
    fi
  else
    printf 'Found %d blocked package/capability pair(s):\n\n' "${#problem_lines[@]}"
    for line in "${problem_lines[@]}"; do
      pkg="$(printf '%s\n' "${line}" | sed -E 's/.*installed package ([^ ]+) requires.*/\1/')"
      cap="$(printf '%s\n' "${line}" | sed -E 's/.*requires ([^,]+), but none.*/\1/')"
      pkg_base="$(printf '%s\n' "${pkg}" | sed -E 's/-[0-9].*//')"

      provider=""
      lib_base=""
      if provider="$("${RPM_BIN}" -q --whatprovides "${cap}" 2>/dev/null | head -1)" && [ -n "${provider}" ]; then
        lib_base="$("${RPM_BIN}" -q --qf '%{NAME}\n' "${provider}" 2>/dev/null || true)"
      fi

      printf -- '- Blocked package: `%s`\n' "${pkg}"
      printf '  - Missing capability: `%s`\n' "${cap}"
      if [ -n "${lib_base}" ]; then
        printf '  - Currently provided by: `%s` (installed)\n' "${provider}"
        printf '  - Suggested fix: `./scripts/generate_dnf_rebuild_fix.sh %s`\n' "${pkg_base}"
      else
        printf '  - Could not determine the current provider of `%s`; inspect manually with `rpm -q --whatprovides '"'"'%s'"'"'`.\n' "${cap}" "${cap}"
      fi
      printf '\n'
    done
  fi
} >"${report}"

cat "${report}"
if [ -n "${OUTPUT_FILE}" ]; then
  mkdir -p "$(dirname "${OUTPUT_FILE}")"
  cp "${report}" "${OUTPUT_FILE}"
fi
rm -f "${report}"

[ "${#problem_lines[@]}" -eq 0 ]
