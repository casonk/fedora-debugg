#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT_BASE="${ROOT_DIR}/artifacts"
PATH_ONLY=0
HISTORY_LINES=5000
TARGET_USER=""
TARGET_HOME=""
DNF_HOME="/tmp/fedora-debugg-dnf-home"
DNF_STATE_HOME="/tmp/fedora-debugg-dnf-state"

usage() {
  cat <<'EOF'
Usage: ./scripts/analyze_installed_software.sh [options]

Analyze currently installed software and generate a local review report that
helps answer:
  - What is installed?
  - What package source owns it?
  - Is there evidence that it is used?
  - Is it an immediate uninstall candidate or only a manual-review candidate?

Options:
  --output-dir <dir>      Output base directory (default: ./artifacts).
  --history-lines <n>     Tail this many shell-history lines for app-usage hints
                          (default: 5000).
  --path-only             Print only the generated report path.
  --help                  Show this help message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --output-dir)
      [ $# -lt 2 ] && { echo "Missing value for --output-dir" >&2; exit 1; }
      OUTPUT_BASE="$2"
      shift 2
      ;;
    --history-lines)
      [ $# -lt 2 ] && { echo "Missing value for --history-lines" >&2; exit 1; }
      HISTORY_LINES="$2"
      shift 2
      ;;
    --path-only)
      PATH_ONLY=1
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

case "${OUTPUT_BASE}" in
  /*) ;;
  *) OUTPUT_BASE="${ROOT_DIR}/${OUTPUT_BASE}" ;;
esac

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="${OUTPUT_BASE}/software-audit-${TIMESTAMP}"
COMMANDS_DIR="${REPORT_DIR}/commands"
TABLES_DIR="${REPORT_DIR}/tables"
STATUS_FILE="${COMMANDS_DIR}/command-status.tsv"
SUMMARY_FILE="${REPORT_DIR}/software-summary.md"

mkdir -p "${COMMANDS_DIR}" "${TABLES_DIR}"

log() {
  if [ "${PATH_ONLY}" -eq 0 ]; then
    printf '[software] %s\n' "$*"
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sanitize_field() {
  local value="${1:-}"
  value="${value//$'\t'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  printf '%s' "${value}"
}

record_command_status() {
  local file_name="$1"
  local status="$2"
  shift 2
  local cmd=("$@")
  {
    printf '%s\t%s\t' "${file_name}" "${status}"
    printf '%q ' "${cmd[@]}"
    printf '\n'
  } >>"${STATUS_FILE}"
}

write_cmd_output() {
  local file_name="$1"
  shift
  local out_file="${COMMANDS_DIR}/${file_name}"
  local err_file="${out_file}.stderr"
  local cmd=("$@")
  local status

  : >"${out_file}"
  rm -f "${err_file}"

  if ! has_cmd "${cmd[0]}"; then
    record_command_status "${file_name}" "127" "${cmd[@]}"
    return 0
  fi

  "${cmd[@]}" >"${out_file}" 2>"${err_file}"
  status=$?
  record_command_status "${file_name}" "${status}" "${cmd[@]}"
  if [ ! -s "${err_file}" ]; then
    rm -f "${err_file}"
  fi
  return 0
}

write_cmd_output_with_timeout() {
  local file_name="$1"
  local timeout_seconds="$2"
  shift 2
  local out_file="${COMMANDS_DIR}/${file_name}"
  local err_file="${out_file}.stderr"
  local cmd=("$@")
  local status

  : >"${out_file}"
  rm -f "${err_file}"

  if ! has_cmd "${cmd[0]}"; then
    record_command_status "${file_name}" "127" "${cmd[@]}"
    return 0
  fi

  if has_cmd timeout; then
    timeout "${timeout_seconds}" "${cmd[@]}" >"${out_file}" 2>"${err_file}"
    status=$?
  else
    "${cmd[@]}" >"${out_file}" 2>"${err_file}"
    status=$?
  fi

  record_command_status "${file_name}" "${status}" "${cmd[@]}"
  if [ ! -s "${err_file}" ]; then
    rm -f "${err_file}"
  fi
  return 0
}

increment_map() {
  local map_name="$1"
  local key="$2"
  local amount="${3:-1}"
  local -n map_ref="${map_name}"
  map_ref["${key}"]=$(( ${map_ref["${key}"]:-0} + amount ))
}

append_unique_list() {
  local map_name="$1"
  local key="$2"
  local value="$3"
  local -n map_ref="${map_name}"
  local current

  [ -n "${value}" ] || return 0
  current="${map_ref["${key}"]:-}"
  case ",${current}," in
    *,"${value}",*) ;;
    *)
      map_ref["${key}"]="${current:+${current},}${value}"
      ;;
  esac
}

resolve_target_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    TARGET_USER="${SUDO_USER}"
  elif [ -n "${USER:-}" ]; then
    TARGET_USER="${USER}"
  else
    TARGET_USER="unknown"
  fi

  TARGET_HOME="$(getent passwd "${TARGET_USER}" 2>/dev/null | awk -F: '{print $6}')"
  if [ -z "${TARGET_HOME}" ]; then
    TARGET_HOME="${HOME:-/home/${TARGET_USER}}"
  fi
}

load_set_from_file() {
  local file="$1"
  local map_name="$2"
  local -n map_ref="${map_name}"
  local line

  [ -f "${file}" ] || return 0
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    map_ref["${line}"]=1
  done <"${file}"
}

rpm_owner_nevra() {
  local path="$1"

  [ -e "${path}" ] || return 0
  rpm -q --qf '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' -f "${path}" 2>/dev/null | head -n 1
}

desktop_value() {
  local file="$1"
  local key="$2"
  awk -F= -v key="${key}" '
    $1 == key {
      sub(/^[^=]+= */, "", $0)
      print $0
      exit
    }
  ' "${file}" 2>/dev/null
}

desktop_exec_basename() {
  local exec_line="$1"
  local token
  local skip_next=0

  for token in ${exec_line}; do
    if [ "${skip_next}" -eq 1 ]; then
      skip_next=0
      continue
    fi
    case "${token}" in
      env)
        continue
        ;;
      -u|-S)
        skip_next=1
        continue
        ;;
      *=*)
        continue
        ;;
      %*)
        continue
        ;;
      *)
        token="${token##*/}"
        token="${token%\"}"
        token="${token#\"}"
        token="${token%\'}"
        token="${token#\'}"
        printf '%s\n' "${token,,}"
        return 0
        ;;
    esac
  done

  printf '\n'
}

build_search_terms() {
  local input

  for input in "$@"; do
    [ -n "${input}" ] && printf '%s\n' "${input}"
  done | awk '
    BEGIN {
      split("app application apps binary browser client com command desktop dev editor fedora file files flatpak gnome gui helper io launcher local net org panel player run service settings share snap suite system the usr viewer bin", stop_words, " ")
      for (i in stop_words) {
        stop[stop_words[i]] = 1
      }
    }
    {
      raw = tolower($0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", raw)
      if (length(raw) >= 3 && raw !~ /[[:space:]]/ && !stop[raw] && !seen[raw]++) {
        print raw
      }

      line = raw
      gsub(/[^[:alnum:].+_-]+/, " ", line)
      count = split(line, parts, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        token = parts[i]
        gsub(/^[._+-]+|[._+-]+$/, "", token)
        if (length(token) < 3) {
          continue
        }
        if (token ~ /^[0-9]+$/) {
          continue
        }
        if (stop[token]) {
          continue
        }
        if (!seen[token]++) {
          print token
        }
      }
    }
  '
}

grep_sample_hits() {
  local sample="$1"
  shift
  local -a cmd=(grep -iF)
  local term

  [ -n "${sample}" ] || { echo "0"; return 0; }

  for term in "$@"; do
    [ -n "${term}" ] || continue
    cmd+=(-e "${term}")
  done

  if [ "${#cmd[@]}" -le 2 ]; then
    echo "0"
    return 0
  fi

  printf '%s\n' "${sample}" | "${cmd[@]}" 2>/dev/null | wc -l | tr -d ' '
}

config_hits_and_samples() {
  local paths_blob="$1"
  shift
  local count=0
  local sample_count=0
  local sample_paths=""
  local path
  local base_lower
  local term
  local matched

  [ -n "${paths_blob}" ] || { printf '0\t\n'; return 0; }

  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    base_lower="${path##*/}"
    base_lower="${base_lower,,}"
    matched=0
    for term in "$@"; do
      [ -n "${term}" ] || continue
      case "${base_lower}" in
        *"${term}"*)
          matched=1
          break
          ;;
      esac
    done

    if [ "${matched}" -eq 1 ]; then
      count=$((count + 1))
      if [ "${sample_count}" -lt 3 ]; then
        sample_paths="${sample_paths}${sample_paths:+,}${path}"
        sample_count=$((sample_count + 1))
      fi
    fi
  done <<<"${paths_blob}"

  printf '%s\t%s\n' "${count}" "${sample_paths}"
}

human_bytes() {
  local bytes="${1:-0}"
  awk -v bytes="${bytes}" '
    BEGIN {
      split("B KiB MiB GiB TiB", units, " ")
      idx = 1
      while (bytes >= 1024 && idx < 5) {
        bytes /= 1024
        idx++
      }
      if (idx == 1) {
        printf "%.0f %s", bytes, units[idx]
      } else {
        printf "%.1f %s", bytes, units[idx]
      }
    }
  '
}

package_class() {
  local name="$1"
  local reason="$2"
  local desktop_count="$3"
  local service_count="$4"

  if [ "${desktop_count}" -gt 0 ]; then
    echo "desktop-app"
  elif [ "${service_count}" -gt 0 ]; then
    echo "service"
  elif [[ "${name}" == *-devel ]]; then
    echo "devel"
  elif [[ "${name}" == *-doc ]] || [[ "${name}" == *-docs ]]; then
    echo "docs"
  elif [[ "${name}" == *-langpack* ]] || [[ "${name}" == *-fonts* ]]; then
    echo "content"
  elif [ "${reason}" = "Dependency" ] || [ "${reason}" = "Weak Dependency" ]; then
    echo "dependency"
  else
    echo "package"
  fi
}

app_hint() {
  local source="$1"
  local owner_key="$2"
  local running_count="$3"
  local autostart="$4"
  local history_hits="$5"
  local config_hits="$6"

  if [ -n "${owner_key}" ] && [ -n "${RPM_UNNEEDED["${owner_key}"]:-}" ]; then
    echo "candidate"
  elif [ "${running_count}" -gt 0 ] || [ "${autostart}" = "yes" ] || [ "${history_hits}" -gt 0 ]; then
    echo "keep"
  elif [ "${config_hits}" -gt 0 ]; then
    echo "review"
  elif [ "${source}" = "flatpak" ] || [ "${source}" = "snap" ]; then
    echo "review"
  else
    echo "review"
  fi
}

package_hint() {
  local key="$1"
  local running_count="$2"
  local enabled_count="$3"
  local autostart_count="$4"
  local used_apps="$5"
  local leaf="$6"

  if [ -n "${RPM_UNNEEDED["${key}"]:-}" ]; then
    echo "candidate"
  elif [ "${running_count}" -gt 0 ] || [ "${enabled_count}" -gt 0 ] || [ "${autostart_count}" -gt 0 ] || [ "${used_apps}" -gt 0 ]; then
    echo "keep"
  elif [ "${leaf}" = "yes" ]; then
    echo "review"
  else
    echo "keep"
  fi
}

app_reason_summary() {
  local source="$1"
  local running_count="$2"
  local autostart="$3"
  local history_hits="$4"
  local config_hits="$5"
  local owner_key="$6"
  local parts=""

  parts="source=${source}"
  parts="${parts},running=${running_count}"
  parts="${parts},autostart=${autostart}"
  parts="${parts},history=${history_hits}"
  parts="${parts},config=${config_hits}"
  if [ -n "${owner_key}" ] && [ -n "${RPM_UNNEEDED["${owner_key}"]:-}" ]; then
    parts="${parts},owner_unneeded=yes"
  fi
  printf '%s\n' "${parts}"
}

package_reason_summary() {
  local key="$1"
  local leaf="$2"
  local running_count="$3"
  local enabled_count="$4"
  local desktop_count="$5"
  local used_apps="$6"
  local parts=""

  parts="leaf=${leaf}"
  parts="${parts},unneeded=$([ -n "${RPM_UNNEEDED["${key}"]:-}" ] && echo yes || echo no)"
  parts="${parts},running=${running_count}"
  parts="${parts},enabled_units=${enabled_count}"
  parts="${parts},desktop_entries=${desktop_count}"
  parts="${parts},used_apps=${used_apps}"
  printf '%s\n' "${parts}"
}

app_running_from_processes() {
  local exec_name="$1"
  shift
  local count=0
  local pids=""
  local pid
  local comm
  local args_lower
  local exec_lower="${exec_name,,}"
  local term
  local matched

  for pid in "${PROCESS_ORDER[@]}"; do
    comm="${PROCESS_COMM["${pid}"]:-}"
    args_lower="${PROCESS_ARGS["${pid}"]:-}"
    matched=0

    if [ -n "${exec_lower}" ] && [ "${comm,,}" = "${exec_lower}" ]; then
      matched=1
    elif [ -n "${exec_lower}" ]; then
      case "${args_lower}" in
        *"/${exec_lower}"*|*" ${exec_lower}"*)
          matched=1
          ;;
      esac
    fi

    if [ "${matched}" -eq 0 ]; then
      for term in "$@"; do
        [ -n "${term}" ] || continue
        case "${args_lower}" in
          *"${term}"*)
            matched=1
            break
            ;;
        esac
      done
    fi

    if [ "${matched}" -eq 1 ]; then
      count=$((count + 1))
      pids="${pids}${pids:+,}${pid}:${comm}"
    fi
  done

  printf '%s\t%s\n' "${count}" "${pids}"
}

resolve_target_user

mkdir -p "${DNF_HOME}" "${DNF_STATE_HOME}"

{
  printf 'file\tstatus\tcommand\n'
} >"${STATUS_FILE}"

log "Writing software report to ${REPORT_DIR}"

write_cmd_output "timestamp.txt" date --iso-8601=seconds
write_cmd_output "rpm-installed.tsv" \
  env HOME="${DNF_HOME}" XDG_STATE_HOME="${DNF_STATE_HOME}" \
  dnf repoquery --installed \
  --qf $'%{full_nevra}\t%{name}\t%{arch}\t%{reason}\t%{installtime}\t%{installsize}\t%{from_repo}\t%{summary}\n'
write_cmd_output "rpm-userinstalled.txt" env HOME="${DNF_HOME}" XDG_STATE_HOME="${DNF_STATE_HOME}" dnf repoquery --userinstalled --qf $'%{full_nevra}\n'
write_cmd_output "rpm-leaves.txt" env HOME="${DNF_HOME}" XDG_STATE_HOME="${DNF_STATE_HOME}" dnf repoquery --leaves --qf $'%{full_nevra}\n'
write_cmd_output "rpm-unneeded.txt" env HOME="${DNF_HOME}" XDG_STATE_HOME="${DNF_STATE_HOME}" dnf repoquery --unneeded --qf $'%{full_nevra}\n'
write_cmd_output "process-list.tsv" ps -eo pid=,comm=,args= --no-headers
write_cmd_output "desktop-files.txt" bash -lc "find /usr/share/applications \"${TARGET_HOME}/.local/share/applications\" -maxdepth 1 -type f -name '*.desktop' 2>/dev/null | sort"
write_cmd_output "autostart-files.txt" bash -lc "find /etc/xdg/autostart \"${TARGET_HOME}/.config/autostart\" -maxdepth 1 -type f -name '*.desktop' 2>/dev/null | sort"
write_cmd_output "system-service-files.txt" bash -lc "find /usr/lib/systemd/system -maxdepth 1 -type f -name '*.service' 2>/dev/null | sort"
write_cmd_output "user-service-files.txt" bash -lc "find /usr/lib/systemd/user -maxdepth 1 -type f -name '*.service' 2>/dev/null | sort"
write_cmd_output "enabled-service-links.txt" bash -lc "find /etc/systemd/system /etc/systemd/user \"${TARGET_HOME}/.config/systemd/user\" -type l -name '*.service' 2>/dev/null | sort"
write_cmd_output "flatpak-apps.tsv" flatpak list --app --columns=application,name,branch,origin,installation
write_cmd_output "flatpak-runtimes.tsv" flatpak list --runtime --columns=application,name,branch,origin,installation
write_cmd_output "flatpak-ps.tsv" flatpak ps --columns=application,pid
write_cmd_output "snap-desktop-files.txt" bash -lc "find /var/lib/snapd/desktop/applications -maxdepth 1 -type f -name '*.desktop' 2>/dev/null | sort"
write_cmd_output_with_timeout "snap-list.txt" 5 snap list

declare -A RPM_NAME
declare -A RPM_ARCH
declare -A RPM_REASON
declare -A RPM_INSTALLTIME
declare -A RPM_INSTALLSIZE
declare -A RPM_FROM_REPO
declare -A RPM_SUMMARY
declare -A RPM_USERINSTALLED
declare -A RPM_LEAVES
declare -A RPM_UNNEEDED
declare -A RPM_DESKTOP_COUNT
declare -A RPM_DESKTOP_IDS
declare -A RPM_AUTOSTART_COUNT
declare -A RPM_AUTOSTART_FILES
declare -A RPM_SERVICE_COUNT
declare -A RPM_SERVICE_UNITS
declare -A RPM_ENABLED_SERVICE_COUNT
declare -A RPM_ENABLED_SERVICE_UNITS
declare -A RPM_RUNNING_COUNT
declare -A RPM_RUNNING_PIDS
declare -A RPM_APP_COUNT
declare -A RPM_USED_APP_COUNT
declare -A AUTOSTART_BASENAME
declare -A ENABLED_SERVICE_BASENAME
declare -A PROCESS_COMM
declare -A PROCESS_ARGS
declare -A FLATPAK_RUNNING_COUNT
declare -A FLATPAK_RUNNING_PIDS

load_set_from_file "${COMMANDS_DIR}/rpm-userinstalled.txt" RPM_USERINSTALLED
load_set_from_file "${COMMANDS_DIR}/rpm-leaves.txt" RPM_LEAVES
load_set_from_file "${COMMANDS_DIR}/rpm-unneeded.txt" RPM_UNNEEDED

if [ -f "${COMMANDS_DIR}/rpm-installed.tsv" ]; then
  while IFS=$'\t' read -r full_nevra name arch reason installtime installsize from_repo summary; do
    [ -n "${full_nevra}" ] || continue
    RPM_NAME["${full_nevra}"]="${name}"
    RPM_ARCH["${full_nevra}"]="${arch}"
    RPM_REASON["${full_nevra}"]="${reason}"
    RPM_INSTALLTIME["${full_nevra}"]="${installtime}"
    RPM_INSTALLSIZE["${full_nevra}"]="${installsize}"
    RPM_FROM_REPO["${full_nevra}"]="${from_repo}"
    RPM_SUMMARY["${full_nevra}"]="${summary}"
  done <"${COMMANDS_DIR}/rpm-installed.tsv"
fi

if [ -f "${COMMANDS_DIR}/autostart-files.txt" ]; then
  while IFS= read -r file_path; do
    [ -n "${file_path}" ] || continue
    AUTOSTART_BASENAME["$(basename "${file_path}")"]=1
  done <"${COMMANDS_DIR}/autostart-files.txt"
fi

if [ -f "${COMMANDS_DIR}/enabled-service-links.txt" ]; then
  while IFS= read -r file_path; do
    [ -n "${file_path}" ] || continue
    ENABLED_SERVICE_BASENAME["$(basename "${file_path}")"]=1
  done <"${COMMANDS_DIR}/enabled-service-links.txt"
fi

if [ -f "${COMMANDS_DIR}/flatpak-ps.tsv" ]; then
  while IFS=$'\t' read -r app_id pid; do
    [ -n "${app_id}" ] || continue
    increment_map FLATPAK_RUNNING_COUNT "${app_id}"
    append_unique_list FLATPAK_RUNNING_PIDS "${app_id}" "${pid}"
  done <"${COMMANDS_DIR}/flatpak-ps.tsv"
fi

PROCESS_ORDER=()
if [ -f "${COMMANDS_DIR}/process-list.tsv" ]; then
  while read -r pid comm args; do
    local_owner=""
    [ -n "${pid}" ] || continue
    PROCESS_ORDER+=("${pid}")
    PROCESS_COMM["${pid}"]="${comm}"
    PROCESS_ARGS["${pid}"]="${args,,}"

    exe_path="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
    if [ -n "${exe_path}" ]; then
      local_owner="$(rpm_owner_nevra "${exe_path}")"
      if [ -n "${local_owner}" ] && [ -n "${RPM_NAME["${local_owner}"]:-}" ]; then
        increment_map RPM_RUNNING_COUNT "${local_owner}"
        append_unique_list RPM_RUNNING_PIDS "${local_owner}" "${pid}:${comm}"
      fi
    fi
  done <"${COMMANDS_DIR}/process-list.tsv"
fi

for service_file_list in "${COMMANDS_DIR}/system-service-files.txt" "${COMMANDS_DIR}/user-service-files.txt"; do
  [ -f "${service_file_list}" ] || continue
  while IFS= read -r unit_path; do
    [ -n "${unit_path}" ] || continue
    unit_owner="$(rpm_owner_nevra "${unit_path}")"
    unit_name="$(basename "${unit_path}")"
    if [ -n "${unit_owner}" ] && [ -n "${RPM_NAME["${unit_owner}"]:-}" ]; then
      increment_map RPM_SERVICE_COUNT "${unit_owner}"
      append_unique_list RPM_SERVICE_UNITS "${unit_owner}" "${unit_name}"
      if [ -n "${ENABLED_SERVICE_BASENAME["${unit_name}"]:-}" ]; then
        increment_map RPM_ENABLED_SERVICE_COUNT "${unit_owner}"
        append_unique_list RPM_ENABLED_SERVICE_UNITS "${unit_owner}" "${unit_name}"
      fi
    fi
  done <"${service_file_list}"
done

declare -A APP_SOURCE
declare -A APP_DISPLAY_NAME
declare -A APP_DESKTOP_ID
declare -A APP_OWNER
declare -A APP_EXEC
declare -A APP_VISIBLE
declare -A APP_AUTOSTART
declare -A APP_RUNNING_COUNT
declare -A APP_RUNNING_PIDS
declare -A APP_HISTORY_HITS
declare -A APP_CONFIG_HITS
declare -A APP_CONFIG_PATHS
declare -A APP_HINT
declare -A APP_WHY

HISTORY_SAMPLE="$(
  {
    [ -f "${TARGET_HOME}/.bash_history" ] && tail -n "${HISTORY_LINES}" "${TARGET_HOME}/.bash_history"
    [ -f "${TARGET_HOME}/.zsh_history" ] && tail -n "${HISTORY_LINES}" "${TARGET_HOME}/.zsh_history"
    [ -f "${TARGET_HOME}/.local/share/fish/fish_history" ] && tail -n "${HISTORY_LINES}" "${TARGET_HOME}/.local/share/fish/fish_history"
  } 2>/dev/null
)"

CONFIG_PATHS="$(
  {
    find "${TARGET_HOME}/.config" -mindepth 1 -maxdepth 1 2>/dev/null
    find "${TARGET_HOME}/.local/share" -mindepth 1 -maxdepth 1 2>/dev/null
    find "${TARGET_HOME}/.cache" -mindepth 1 -maxdepth 1 2>/dev/null
  } | sort -u
)"

if [ -f "${COMMANDS_DIR}/desktop-files.txt" ]; then
  while IFS= read -r desktop_file; do
    [ -n "${desktop_file}" ] || continue

    desktop_type="$(desktop_value "${desktop_file}" "Type")"
    [ "${desktop_type}" = "Application" ] || continue

    app_key="desktop:$(basename "${desktop_file}")"
    desktop_name="$(desktop_value "${desktop_file}" "Name")"
    desktop_exec="$(desktop_value "${desktop_file}" "Exec")"
    exec_base="$(desktop_exec_basename "${desktop_exec}")"
    no_display="$(desktop_value "${desktop_file}" "NoDisplay")"
    hidden="$(desktop_value "${desktop_file}" "Hidden")"
    visible="yes"
    if [ "${no_display,,}" = "true" ] || [ "${hidden,,}" = "true" ]; then
      visible="no"
    fi

    owner_key=""
    if [[ "${desktop_file}" = /usr/share/applications/* ]]; then
      owner_key="$(rpm_owner_nevra "${desktop_file}")"
      if [ -n "${owner_key}" ] && [ -n "${RPM_NAME["${owner_key}"]:-}" ]; then
        increment_map RPM_DESKTOP_COUNT "${owner_key}"
        append_unique_list RPM_DESKTOP_IDS "${owner_key}" "$(basename "${desktop_file}")"
        if [ -n "${AUTOSTART_BASENAME["$(basename "${desktop_file}")"]:-}" ]; then
          increment_map RPM_AUTOSTART_COUNT "${owner_key}"
          append_unique_list RPM_AUTOSTART_FILES "${owner_key}" "$(basename "${desktop_file}")"
        fi
      fi
    fi

    mapfile -t search_terms < <(
      build_search_terms \
        "${desktop_name}" \
        "$(basename "${desktop_file}" .desktop)" \
        "${exec_base}" \
        "${RPM_NAME["${owner_key}"]:-}"
    )

    history_hits="$(grep_sample_hits "${HISTORY_SAMPLE}" "${search_terms[@]}")"
    config_info="$(config_hits_and_samples "${CONFIG_PATHS}" "${search_terms[@]}")"
    config_hits="${config_info%%$'\t'*}"
    config_paths="${config_info#*$'\t'}"
    running_info="$(app_running_from_processes "${exec_base}" "${search_terms[@]}")"
    running_count="${running_info%%$'\t'*}"
    running_pids="${running_info#*$'\t'}"
    autostart="no"
    if [ -n "${AUTOSTART_BASENAME["$(basename "${desktop_file}")"]:-}" ]; then
      autostart="yes"
    fi

    app_source="local"
    if [ -n "${owner_key}" ] && [ -n "${RPM_NAME["${owner_key}"]:-}" ]; then
      app_source="rpm"
    fi

    APP_SOURCE["${app_key}"]="${app_source}"
    APP_DISPLAY_NAME["${app_key}"]="${desktop_name:-$(basename "${desktop_file}" .desktop)}"
    APP_DESKTOP_ID["${app_key}"]="$(basename "${desktop_file}")"
    APP_OWNER["${app_key}"]="${owner_key}"
    APP_EXEC["${app_key}"]="${desktop_exec}"
    APP_VISIBLE["${app_key}"]="${visible}"
    APP_AUTOSTART["${app_key}"]="${autostart}"
    APP_RUNNING_COUNT["${app_key}"]="${running_count}"
    APP_RUNNING_PIDS["${app_key}"]="${running_pids}"
    APP_HISTORY_HITS["${app_key}"]="${history_hits}"
    APP_CONFIG_HITS["${app_key}"]="${config_hits}"
    APP_CONFIG_PATHS["${app_key}"]="${config_paths}"
    APP_HINT["${app_key}"]="$(app_hint "${app_source}" "${owner_key}" "${running_count}" "${autostart}" "${history_hits}" "${config_hits}")"
    APP_WHY["${app_key}"]="$(app_reason_summary "${app_source}" "${running_count}" "${autostart}" "${history_hits}" "${config_hits}" "${owner_key}")"

    if [ -n "${owner_key}" ] && [ -n "${RPM_NAME["${owner_key}"]:-}" ]; then
      increment_map RPM_APP_COUNT "${owner_key}"
      if [ "${APP_HINT["${app_key}"]}" = "keep" ]; then
        increment_map RPM_USED_APP_COUNT "${owner_key}"
      fi
    fi
  done <"${COMMANDS_DIR}/desktop-files.txt"
fi

if [ -f "${COMMANDS_DIR}/flatpak-apps.tsv" ]; then
  while IFS=$'\t' read -r app_id app_name branch origin installation; do
    [ -n "${app_id}" ] || continue
    app_key="flatpak:${app_id}"

    mapfile -t search_terms < <(build_search_terms "${app_id}" "${app_name}" "${app_name%% *}")
    history_hits="$(grep_sample_hits "${HISTORY_SAMPLE}" "${search_terms[@]}")"
    config_info="$(config_hits_and_samples "${CONFIG_PATHS}" "${search_terms[@]}")"
    config_hits="${config_info%%$'\t'*}"
    config_paths="${config_info#*$'\t'}"
    running_count="${FLATPAK_RUNNING_COUNT["${app_id}"]:-0}"
    running_pids="${FLATPAK_RUNNING_PIDS["${app_id}"]:-}"
    autostart="no"
    if [ -n "${AUTOSTART_BASENAME["${app_id}.desktop"]:-}" ]; then
      autostart="yes"
    fi

    APP_SOURCE["${app_key}"]="flatpak"
    APP_DISPLAY_NAME["${app_key}"]="${app_name:-${app_id}}"
    APP_DESKTOP_ID["${app_key}"]="${app_id}.desktop"
    APP_OWNER["${app_key}"]="${app_id}"
    APP_EXEC["${app_key}"]="flatpak run ${app_id}"
    APP_VISIBLE["${app_key}"]="yes"
    APP_AUTOSTART["${app_key}"]="${autostart}"
    APP_RUNNING_COUNT["${app_key}"]="${running_count}"
    APP_RUNNING_PIDS["${app_key}"]="${running_pids}"
    APP_HISTORY_HITS["${app_key}"]="${history_hits}"
    APP_CONFIG_HITS["${app_key}"]="${config_hits}"
    APP_CONFIG_PATHS["${app_key}"]="${config_paths}"
    APP_HINT["${app_key}"]="$(app_hint "flatpak" "" "${running_count}" "${autostart}" "${history_hits}" "${config_hits}")"
    APP_WHY["${app_key}"]="$(app_reason_summary "flatpak" "${running_count}" "${autostart}" "${history_hits}" "${config_hits}" "")"
  done <"${COMMANDS_DIR}/flatpak-apps.tsv"
fi

if [ -f "${COMMANDS_DIR}/snap-desktop-files.txt" ]; then
  while IFS= read -r desktop_file; do
    [ -n "${desktop_file}" ] || continue

    desktop_type="$(desktop_value "${desktop_file}" "Type")"
    [ "${desktop_type}" = "Application" ] || continue

    app_key="snap:$(basename "${desktop_file}")"
    desktop_name="$(desktop_value "${desktop_file}" "Name")"
    desktop_exec="$(desktop_value "${desktop_file}" "Exec")"
    exec_base="$(desktop_exec_basename "${desktop_exec}")"
    snap_instance="$(desktop_value "${desktop_file}" "X-SnapInstanceName")"
    if [ -z "${snap_instance}" ]; then
      snap_instance="$(basename "${desktop_file}" .desktop)"
      snap_instance="${snap_instance%%_*}"
    fi

    no_display="$(desktop_value "${desktop_file}" "NoDisplay")"
    hidden="$(desktop_value "${desktop_file}" "Hidden")"
    visible="yes"
    if [ "${no_display,,}" = "true" ] || [ "${hidden,,}" = "true" ]; then
      visible="no"
    fi

    mapfile -t search_terms < <(build_search_terms "${desktop_name}" "${snap_instance}" "$(basename "${desktop_file}" .desktop)" "${exec_base}")
    history_hits="$(grep_sample_hits "${HISTORY_SAMPLE}" "${search_terms[@]}")"
    config_info="$(config_hits_and_samples "${CONFIG_PATHS}" "${search_terms[@]}")"
    config_hits="${config_info%%$'\t'*}"
    config_paths="${config_info#*$'\t'}"
    running_info="$(app_running_from_processes "${exec_base}" "${search_terms[@]}")"
    running_count="${running_info%%$'\t'*}"
    running_pids="${running_info#*$'\t'}"
    autostart="no"
    if [ -n "${AUTOSTART_BASENAME["$(basename "${desktop_file}")"]:-}" ]; then
      autostart="yes"
    fi

    APP_SOURCE["${app_key}"]="snap"
    APP_DISPLAY_NAME["${app_key}"]="${desktop_name:-$(basename "${desktop_file}" .desktop)}"
    APP_DESKTOP_ID["${app_key}"]="$(basename "${desktop_file}")"
    APP_OWNER["${app_key}"]="${snap_instance}"
    APP_EXEC["${app_key}"]="${desktop_exec}"
    APP_VISIBLE["${app_key}"]="${visible}"
    APP_AUTOSTART["${app_key}"]="${autostart}"
    APP_RUNNING_COUNT["${app_key}"]="${running_count}"
    APP_RUNNING_PIDS["${app_key}"]="${running_pids}"
    APP_HISTORY_HITS["${app_key}"]="${history_hits}"
    APP_CONFIG_HITS["${app_key}"]="${config_hits}"
    APP_CONFIG_PATHS["${app_key}"]="${config_paths}"
    APP_HINT["${app_key}"]="$(app_hint "snap" "" "${running_count}" "${autostart}" "${history_hits}" "${config_hits}")"
    APP_WHY["${app_key}"]="$(app_reason_summary "snap" "${running_count}" "${autostart}" "${history_hits}" "${config_hits}" "")"
  done <"${COMMANDS_DIR}/snap-desktop-files.txt"
fi

PACKAGES_FILE="${TABLES_DIR}/rpm-packages.tsv"
APPLICATIONS_FILE="${TABLES_DIR}/applications.tsv"
RPM_REVIEW_FILE="${TABLES_DIR}/rpm-removal-review.tsv"
APP_REVIEW_FILE="${TABLES_DIR}/application-removal-review.tsv"
FLATPAK_RUNTIMES_FILE="${TABLES_DIR}/flatpak-runtimes.tsv"

{
  printf 'hint\tclass\tfull_nevra\tname\tarch\treason\tuserinstalled\tleaf\tunneeded\tinstalltime_epoch\tinstallsize_bytes\tinstallsize_human\tfrom_repo\tdesktop_entries\tdesktop_ids\tautostart_entries\tautostart_files\tservice_units\tenabled_service_units\trunning_processes\trunning_pids\towned_apps\tused_apps\tsummary\twhy\n'
  mapfile -t package_keys < <(printf '%s\n' "${!RPM_NAME[@]}" | sort)
  for key in "${package_keys[@]}"; do
    [ -n "${key}" ] || continue
    leaf="no"
    [ -n "${RPM_LEAVES["${key}"]:-}" ] && leaf="yes"
    unneeded="no"
    [ -n "${RPM_UNNEEDED["${key}"]:-}" ] && unneeded="yes"
    userinstalled="no"
    [ -n "${RPM_USERINSTALLED["${key}"]:-}" ] && userinstalled="yes"

    hint="$(package_hint "${key}" "${RPM_RUNNING_COUNT["${key}"]:-0}" "${RPM_ENABLED_SERVICE_COUNT["${key}"]:-0}" "${RPM_AUTOSTART_COUNT["${key}"]:-0}" "${RPM_USED_APP_COUNT["${key}"]:-0}" "${leaf}")"
    class_name="$(package_class "${RPM_NAME["${key}"]}" "${RPM_REASON["${key}"]}" "${RPM_DESKTOP_COUNT["${key}"]:-0}" "${RPM_SERVICE_COUNT["${key}"]:-0}")"
    why="$(package_reason_summary "${key}" "${leaf}" "${RPM_RUNNING_COUNT["${key}"]:-0}" "${RPM_ENABLED_SERVICE_COUNT["${key}"]:-0}" "${RPM_DESKTOP_COUNT["${key}"]:-0}" "${RPM_USED_APP_COUNT["${key}"]:-0}")"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${hint}" \
      "${class_name}" \
      "${key}" \
      "$(sanitize_field "${RPM_NAME["${key}"]}")" \
      "$(sanitize_field "${RPM_ARCH["${key}"]}")" \
      "$(sanitize_field "${RPM_REASON["${key}"]}")" \
      "${userinstalled}" \
      "${leaf}" \
      "${unneeded}" \
      "$(sanitize_field "${RPM_INSTALLTIME["${key}"]}")" \
      "$(sanitize_field "${RPM_INSTALLSIZE["${key}"]}")" \
      "$(human_bytes "${RPM_INSTALLSIZE["${key}"]:-0}")" \
      "$(sanitize_field "${RPM_FROM_REPO["${key}"]}")" \
      "${RPM_DESKTOP_COUNT["${key}"]:-0}" \
      "$(sanitize_field "${RPM_DESKTOP_IDS["${key}"]:-}")" \
      "${RPM_AUTOSTART_COUNT["${key}"]:-0}" \
      "$(sanitize_field "${RPM_AUTOSTART_FILES["${key}"]:-}")" \
      "${RPM_SERVICE_COUNT["${key}"]:-0}" \
      "$(sanitize_field "${RPM_ENABLED_SERVICE_UNITS["${key}"]:-}")" \
      "${RPM_RUNNING_COUNT["${key}"]:-0}" \
      "$(sanitize_field "${RPM_RUNNING_PIDS["${key}"]:-}")" \
      "${RPM_APP_COUNT["${key}"]:-0}" \
      "${RPM_USED_APP_COUNT["${key}"]:-0}" \
      "$(sanitize_field "${RPM_SUMMARY["${key}"]}")" \
      "${why}"
  done
} >"${PACKAGES_FILE}"

{
  printf 'hint\tsource\tdisplay_name\tdesktop_id\towner\tvisible\tautostart\trunning_count\trunning_pids\thistory_hits\tconfig_hits\tconfig_paths\texec\twhy\n'
  mapfile -t app_keys < <(printf '%s\n' "${!APP_SOURCE[@]}" | sort)
  for key in "${app_keys[@]}"; do
    [ -n "${key}" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${APP_HINT["${key}"]}" \
      "${APP_SOURCE["${key}"]}" \
      "$(sanitize_field "${APP_DISPLAY_NAME["${key}"]}")" \
      "$(sanitize_field "${APP_DESKTOP_ID["${key}"]}")" \
      "$(sanitize_field "${APP_OWNER["${key}"]}")" \
      "$(sanitize_field "${APP_VISIBLE["${key}"]}")" \
      "$(sanitize_field "${APP_AUTOSTART["${key}"]}")" \
      "$(sanitize_field "${APP_RUNNING_COUNT["${key}"]}")" \
      "$(sanitize_field "${APP_RUNNING_PIDS["${key}"]}")" \
      "$(sanitize_field "${APP_HISTORY_HITS["${key}"]}")" \
      "$(sanitize_field "${APP_CONFIG_HITS["${key}"]}")" \
      "$(sanitize_field "${APP_CONFIG_PATHS["${key}"]}")" \
      "$(sanitize_field "${APP_EXEC["${key}"]}")" \
      "$(sanitize_field "${APP_WHY["${key}"]}")"
  done
} >"${APPLICATIONS_FILE}"

{
  printf 'application\tname\tbranch\torigin\tinstallation\n'
  if [ -f "${COMMANDS_DIR}/flatpak-runtimes.tsv" ]; then
    cat "${COMMANDS_DIR}/flatpak-runtimes.tsv"
  fi
} >"${FLATPAK_RUNTIMES_FILE}"

{
  awk 'NR == 1 || $1 != "keep"' "${PACKAGES_FILE}"
} >"${RPM_REVIEW_FILE}"

{
  awk 'NR == 1 || $1 != "keep"' "${APPLICATIONS_FILE}"
} >"${APP_REVIEW_FILE}"

rpm_total=$(( $(wc -l <"${PACKAGES_FILE}") - 1 ))
app_total=$(( $(wc -l <"${APPLICATIONS_FILE}") - 1 ))
flatpak_runtime_total=$(( $(wc -l <"${FLATPAK_RUNTIMES_FILE}") - 1 ))
rpm_unneeded_total="$(awk -F'\t' 'NR > 1 && $1 == "candidate" {count++} END {print count + 0}' "${PACKAGES_FILE}")"
rpm_review_total="$(awk -F'\t' 'NR > 1 && $1 == "review" {count++} END {print count + 0}' "${PACKAGES_FILE}")"
app_review_total="$(awk -F'\t' 'NR > 1 && $1 != "keep" {count++} END {print count + 0}' "${APPLICATIONS_FILE}")"
flatpak_app_total="$(awk -F'\t' 'NR > 1 && $2 == "flatpak" {count++} END {print count + 0}' "${APPLICATIONS_FILE}")"
snap_app_total="$(awk -F'\t' 'NR > 1 && $2 == "snap" {count++} END {print count + 0}' "${APPLICATIONS_FILE}")"
rpm_app_total="$(awk -F'\t' 'NR > 1 && $2 == "rpm" {count++} END {print count + 0}' "${APPLICATIONS_FILE}")"
status_failures="$(awk -F'\t' 'NR > 1 && $2 != "0" {count++} END {print count + 0}' "${STATUS_FILE}")"

{
  echo "Software inventory report created at:"
  echo "  $(date --iso-8601=seconds)"
  echo
  echo "Contains:"
  echo "  - commands/: raw command outputs and command-status.tsv"
  echo "  - tables/rpm-packages.tsv: every installed RPM with usage/removal hints"
  echo "  - tables/applications.tsv: RPM, Flatpak, and Snap apps with usage hints"
  echo "  - tables/rpm-removal-review.tsv: RPM packages worth review or removal"
  echo "  - tables/application-removal-review.tsv: apps without strong usage signals"
  echo "  - tables/flatpak-runtimes.tsv: installed Flatpak runtimes"
  echo "  - software-summary.md: human-readable overview"
  echo
  echo "Notes:"
  echo "  - 'candidate' means DNF currently classifies the RPM as unneeded."
  echo "  - 'review' means weak/no usage evidence was found; it is not proof the item is safe to remove."
  echo "  - Shell history is sampled from the most recent ${HISTORY_LINES} lines per shell history file."
  echo "  - Service enablement is inferred from symlinks when systemctl D-Bus access is unavailable."
} >"${REPORT_DIR}/README.txt"

{
  echo "# Installed Software Analysis"
  echo
  echo "- Report: ${REPORT_DIR}"
  echo "- Generated: $(date --iso-8601=seconds)"
  echo "- Target user: ${TARGET_USER}"
  echo "- History sample size per shell: ${HISTORY_LINES} lines"
  echo
  echo "## Overview"
  echo
  echo "- RPM packages analyzed: ${rpm_total}"
  echo "- Desktop applications analyzed: ${app_total}"
  echo "- RPM desktop launchers: ${rpm_app_total}"
  echo "- Flatpak apps: ${flatpak_app_total}"
  echo "- Snap apps: ${snap_app_total}"
  echo "- Flatpak runtimes: ${flatpak_runtime_total}"
  printf '%s\n' "- High-confidence RPM removal candidates (\`dnf repoquery --unneeded\`): ${rpm_unneeded_total}"
  echo "- RPM review candidates (leaf/no strong activity evidence): ${rpm_review_total}"
  echo "- Application review candidates: ${app_review_total}"
  echo "- Collection commands with non-zero exit status: ${status_failures}"
  echo
  echo "## Evidence Model"
  echo
  echo "- RPM package hints use install reason, leaf/unneeded status, owned desktop entries, autostart entries, service units, enabled-unit symlinks, and currently running processes."
  echo "- Application hints use current processes, autostart launchers, recent shell-history hits, and matching config/cache footprints."
  printf '%s\n' '- `candidate` is intentionally conservative and only assigned to RPMs that DNF already marks as unneeded.'
  printf '%s\n' '- `review` means manual verification is still required. GUI-launched apps, helper binaries, and rarely used tools can look inactive.'
  echo
  echo "## Highest-Confidence RPM Candidates"
  echo
  if [ "${rpm_unneeded_total}" -gt 0 ]; then
    printf '%s\n' '```text'
    awk -F'\t' '
      NR > 1 && $1 == "candidate" {
        printf "%-12s  %-48s  %-12s  %s\n", $12, $4, $6, $25
      }
    ' "${PACKAGES_FILE}" | sed -n '1,25p'
    printf '%s\n' '```'
  else
    echo "No RPM packages are currently classified as unneeded by DNF."
  fi
  echo
  echo "## Application Review Queue"
  echo
  if [ "${app_review_total}" -gt 0 ]; then
    printf '%s\n' '```text'
    awk -F'\t' '
      NR > 1 && $1 != "keep" && $6 == "yes" {
        printf "%-8s  %-36s  running=%-3s history=%-3s config=%-3s autostart=%-3s owner=%s\n", $2, $3, $8, $10, $11, $7, $5
      }
    ' "${APPLICATIONS_FILE}" | sed -n '1,25p'
    printf '%s\n' '```'
  else
    echo "No application launchers landed in the review queue."
  fi
  echo
  echo "## RPM Review Queue"
  echo
  if [ "${rpm_review_total}" -gt 0 ]; then
    printf '%s\n' '```text'
    awk -F'\t' '
      NR > 1 && $1 == "review" {
        printf "%-14s  %-48s  apps=%-3s services=%-3s running=%-3s reason=%s\n", $2, $4, $22, $18, $20, $6
      }
    ' "${PACKAGES_FILE}" | sed -n '1,25p'
    printf '%s\n' '```'
  else
    echo "No additional RPM packages landed in the review queue."
  fi
  echo
  echo "## Next Commands"
  echo
  echo "- Inspect all RPM rows: \`column -t -s \$'\\t' ${PACKAGES_FILE} | less -S\`"
  echo "- Inspect all application rows: \`column -t -s \$'\\t' ${APPLICATIONS_FILE} | less -S\`"
  echo "- Drill into a package before removal: \`dnf repoquery --installed --whatrequires <package>\`"
  echo "- Compare DNF's removable set directly: \`dnf repoquery --unneeded\`"
  echo "- Remove only after manual review; this utility does not uninstall anything."
} >"${SUMMARY_FILE}"

ln -sfn "$(basename "${REPORT_DIR}")" "${OUTPUT_BASE}/software-latest"

if [ "${PATH_ONLY}" -eq 1 ]; then
  printf '%s\n' "${REPORT_DIR}"
else
  log "Software analysis finished."
  printf 'REPORT_DIR=%s\n' "${REPORT_DIR}"
  printf 'SUMMARY=%s\n' "${SUMMARY_FILE}"
fi
