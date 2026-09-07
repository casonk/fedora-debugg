#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DNF_BIN="dnf"
RPM_BIN="rpm"
OUTPUT_BASE="${ROOT_DIR}/local/dnf-fixes"
PKG=""

usage() {
  cat <<'EOF'
Usage: ./scripts/generate_dnf_rebuild_fix.sh <package> [--output-dir <dir>] [--dnf <path>] [--rpm <path>]

Generates a ready-to-run remediation script for the soname-bump conflict
class reported by detect_dnf_upgrade_blockers.sh: <package> is installed,
requires a soname that the newest available build of some library no
longer provides, and so dnf refuses to upgrade that library.

This script itself never touches installed packages or runs anything with
sudo - it only downloads <package>'s source RPM (`dnf download --source`,
enabling the disabled *-source repos just for this call) and inspects it.
It writes the actual fix - which does need sudo, since it force-installs
the newer library and rebuilds/reinstalls <package> against it - to
local/dnf-fixes/<package>/rebuild-<package>.sh for you to review and run
yourself. See the Sudo Boundary section of AGENTS.md.

Options:
  --output-dir <dir>   Base directory for generated fixes (default: local/dnf-fixes).
  --dnf <path>          Override the dnf binary (used by tests).
  --rpm <path>          Override the rpm binary (used by tests).
  --help                Show this help message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --output-dir)
      [ $# -ge 2 ] || { echo "Missing value for --output-dir" >&2; exit 1; }
      OUTPUT_BASE="$2"
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
    -*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [ -n "${PKG}" ]; then
        echo "Unexpected extra argument: $1" >&2
        exit 1
      fi
      PKG="$1"
      shift
      ;;
  esac
done

if [ -z "${PKG}" ]; then
  echo "Missing required <package> argument." >&2
  usage >&2
  exit 1
fi

OUTDIR="${OUTPUT_BASE}/${PKG}"
mkdir -p "${OUTDIR}"

echo "==> Checking dnf update for a blocker matching '${PKG}'"
dnf_output="$("${DNF_BIN}" update --refresh --assumeno 2>&1)" || true
problem_line="$(printf '%s\n' "${dnf_output}" \
  | grep -E "installed package ${PKG}-[^ ]* requires .* but none of the providers can be installed" \
  | head -1)"

if [ -z "${problem_line}" ]; then
  echo "No soname-bump blocker found for '${PKG}' via 'dnf update --refresh --assumeno'." >&2
  echo "Run ./scripts/detect_dnf_upgrade_blockers.sh to see current blockers, if any." >&2
  exit 1
fi

cap="$(printf '%s\n' "${problem_line}" | sed -E 's/.*requires ([^,]+), but none.*/\1/')"
provider="$("${RPM_BIN}" -q --whatprovides "${cap}" 2>/dev/null | head -1)"
if [ -z "${provider}" ]; then
  echo "Could not resolve the current provider of capability '${cap}'." >&2
  exit 1
fi
lib_base="$("${RPM_BIN}" -q --qf '%{NAME}\n' "${provider}" 2>/dev/null)"
if [ -z "${lib_base}" ]; then
  echo "Could not resolve the base package name of provider '${provider}'." >&2
  exit 1
fi

echo "==> Blocked package '${PKG}' requires '${cap}', currently provided by '${provider}' (package: ${lib_base})"

lib_target="$("${DNF_BIN}" repoquery --available --qf '%{name}-%{evr}.%{arch}' "${lib_base}.x86_64" 2>/dev/null | sort -V | tail -1)"
devel_target="$("${DNF_BIN}" repoquery --available --qf '%{name}-%{evr}.%{arch}' "${lib_base}-devel.x86_64" 2>/dev/null | sort -V | tail -1)"

if [ -z "${lib_target}" ] || [ -z "${devel_target}" ]; then
  echo "Could not resolve an available x86_64 build of '${lib_base}' and/or '${lib_base}-devel'." >&2
  echo "This tool assumes the devel package shares the runtime library's base name; inspect manually." >&2
  exit 1
fi

echo "==> Target rebuild dependency: ${lib_target} / ${devel_target}"

echo "==> Downloading source RPM for '${PKG}' (enabling *-source repos for this call only)"
"${DNF_BIN}" download --source --enablerepo=fedora-source --enablerepo=updates-source --destdir "${OUTDIR}" "${PKG}"
srcrpm="$(find "${OUTDIR}" -maxdepth 1 -name "${PKG}-*.src.rpm" | sort | tail -1)"
if [ -z "${srcrpm}" ]; then
  echo "Source RPM download for '${PKG}' did not produce a *.src.rpm in ${OUTDIR}." >&2
  exit 1
fi

RPMBUILD_TOPDIR="${OUTDIR}/rpmbuild"
mkdir -p "${RPMBUILD_TOPDIR}"
"${RPM_BIN}" -ivh --define "_topdir ${RPMBUILD_TOPDIR}" "${srcrpm}"
spec="$(find "${RPMBUILD_TOPDIR}/SPECS" -maxdepth 1 -name '*.spec' | head -1)"
if [ -z "${spec}" ]; then
  echo "Installing the source RPM did not produce a spec file under ${RPMBUILD_TOPDIR}/SPECS." >&2
  exit 1
fi

if grep -E "BuildRequires:[[:space:]]*${lib_base}(-devel)?[[:space:]]*(<|>|=)" "${spec}" >/dev/null 2>&1; then
  echo "WARNING: ${spec} pins a version constraint on ${lib_base}; forcing ${devel_target} may not satisfy it." >&2
  echo "         Review the spec's BuildRequires before running the generated fix script." >&2
fi

FIX_SCRIPT="${OUTDIR}/rebuild-${PKG}.sh"
cat > "${FIX_SCRIPT}" <<SCRIPT
#!/usr/bin/env bash
# Generated by scripts/generate_dnf_rebuild_fix.sh on $(date --iso-8601=seconds)
# Rebuilds ${PKG} against ${lib_target} / ${devel_target} to unblock a dnf
# soname-bump conflict. This performs privileged, hard-to-fully-undo package
# changes (erases and reinstalls ${PKG}) - review before running.
set -euo pipefail

SPEC="${spec}"
LOG="${OUTDIR}/rebuild-${PKG}.log"
exec > >(tee -a "\${LOG}") 2>&1

echo "==> Step 1: force ${lib_target} / ${devel_target} (may erase installed ${PKG})"
sudo dnf install -y --allowerasing "${lib_target}" "${devel_target}" < /dev/null

echo "==> Step 2: rebuild ${PKG}"
rm -f "${RPMBUILD_TOPDIR}/RPMS"/*/"${PKG}-"*.rpm 2>/dev/null || true
rpmbuild -ba "\${SPEC}"

RPM=\$(find "${RPMBUILD_TOPDIR}/RPMS" -name '${PKG}-[0-9]*.rpm' | sort | tail -1)
echo "==> Built: \${RPM}"

echo "==> Step 3: install the rebuilt ${PKG}"
sudo dnf install -y "\${RPM}" < /dev/null

echo "==> Step 4: finish the system update"
sudo dnf update -y < /dev/null

echo "==> Verifying:"
rpm -q ${PKG} ${lib_base}
bin="\$(command -v ${PKG} || true)"
if [ -n "\${bin}" ]; then
  ldd "\${bin}" | grep ${lib_base} || true
fi
SCRIPT
chmod +x "${FIX_SCRIPT}"

echo
echo "==> Generated: ${FIX_SCRIPT}"
echo "==> Review it, then run it yourself (it needs sudo):"
echo "    bash ${FIX_SCRIPT}"
