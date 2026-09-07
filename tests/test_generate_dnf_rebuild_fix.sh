#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
if [ "${KEEP_TMP:-0}" != "1" ]; then
  trap 'rm -rf "${TMP_DIR}"' EXIT
fi

MOCK_BIN="${TMP_DIR}/mock-bin"
OUTPUT_DIR="${TMP_DIR}/out"
mkdir -p "${MOCK_BIN}" "${OUTPUT_DIR}"

# Fake dnf: answers `update --refresh --assumeno`, `download --source ...`,
# and `repoquery --available ...` for a fictitious testpkg/testlib pair.
cat >"${MOCK_BIN}/dnf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  update)
    cat <<'OUT'
Problem: installed package testpkg-1.0-1.fc43.x86_64 requires testlib.so.1()(64bit), but none of the providers can be installed
  - cannot install the best update candidate for package testpkg-1.0-1.fc43.x86_64
OUT
    exit 1
    ;;
  download)
    destdir=""
    prev=""
    for a in "$@"; do
      if [ "${prev}" = "--destdir" ]; then
        destdir="${a}"
      fi
      prev="${a}"
    done
    pkg="${*: -1}"
    : "${destdir:?missing --destdir}"
    touch "${destdir}/${pkg}-1.0-1.fc43.src.rpm"
    exit 0
    ;;
  repoquery)
    query="${*: -1}"
    case "${query}" in
      testlib.x86_64)
        echo "testlib-2.0-1.fc43.x86_64"
        ;;
      testlib-devel.x86_64)
        echo "testlib-devel-2.0-1.fc43.x86_64"
        ;;
    esac
    exit 0
    ;;
  *)
    echo "unexpected dnf invocation: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${MOCK_BIN}/dnf"

# Fake rpm: answers --whatprovides/--qf lookups and -ivh source install by
# dropping a minimal spec file where a real `rpm -ivh` would.
cat >"${MOCK_BIN}/rpm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-q" ] && [ "${2:-}" = "--whatprovides" ]; then
  echo "testlib-1.0-1.fc43.x86_64"
  exit 0
fi
if [ "${1:-}" = "-q" ] && [ "${2:-}" = "--qf" ]; then
  echo "testlib"
  exit 0
fi
if [ "${1:-}" = "-ivh" ]; then
  topdir=""
  prev=""
  for a in "$@"; do
    if [ "${prev}" = "--define" ]; then
      topdir="${a#_topdir }"
    fi
    prev="${a}"
  done
  : "${topdir:?missing --define _topdir}"
  mkdir -p "${topdir}/SPECS" "${topdir}/RPMS/x86_64"
  cat >"${topdir}/SPECS/testpkg.spec" <<'SPEC'
Name: testpkg
Version: 1.0
BuildRequires: testlib-devel
SPEC
  exit 0
fi
echo "unexpected rpm invocation: $*" >&2
exit 1
EOF
chmod +x "${MOCK_BIN}/rpm"

"${ROOT_DIR}/scripts/generate_dnf_rebuild_fix.sh" testpkg \
  --output-dir "${OUTPUT_DIR}" --dnf "${MOCK_BIN}/dnf" --rpm "${MOCK_BIN}/rpm" \
  >"${TMP_DIR}/generate.log" 2>&1

FIX_SCRIPT="${OUTPUT_DIR}/testpkg/rebuild-testpkg.sh"
assert_file_exists "${FIX_SCRIPT}"
[ -x "${FIX_SCRIPT}" ] || fail "expected ${FIX_SCRIPT} to be executable"

assert_contains "${FIX_SCRIPT}" "testlib-2.0-1.fc43.x86_64"
assert_contains "${FIX_SCRIPT}" "testlib-devel-2.0-1.fc43.x86_64"
assert_contains "${FIX_SCRIPT}" "sudo dnf install -y --allowerasing"
assert_contains "${FIX_SCRIPT}" "rpmbuild -ba"
assert_contains "${FIX_SCRIPT}" "sudo dnf update -y"
assert_contains "${FIX_SCRIPT}" "rpm -q testpkg testlib"
assert_contains "${TMP_DIR}/generate.log" "Generated: ${FIX_SCRIPT}"

echo "OK"
