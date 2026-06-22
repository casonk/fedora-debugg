#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ALT_ROOT="${TMP_DIR}/root"
MOCK_BIN="${TMP_DIR}/mock-bin"
OUTPUT_FILE="${TMP_DIR}/output.txt"
mkdir -p \
  "${ALT_ROOT}/etc" \
  "${ALT_ROOT}/var/lib/aide" \
  "${ALT_ROOT}/usr/share/xml/scap/ssg/content" \
  "${MOCK_BIN}"

printf '# freshclam\n' >"${ALT_ROOT}/etc/freshclam.conf"
printf '# aide\n' >"${ALT_ROOT}/etc/aide.conf"
printf '<xml />\n' >"${ALT_ROOT}/usr/share/xml/scap/ssg/content/ssg-fedora-ds.xml"

cat >"${MOCK_BIN}/freshclam" <<'EOF'
#!/usr/bin/env bash
printf 'freshclam ok\n'
EOF

cat >"${MOCK_BIN}/aide" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--init" ]; then
  printf 'aide init ok\n'
  printf 'db\n' >"${ALT_ROOT}/var/lib/aide/aide.db.new.gz"
  exit 0
fi
exit 1
EOF

cat >"${MOCK_BIN}/mv" <<'EOF'
#!/usr/bin/env bash
/usr/bin/mv "$@"
EOF

chmod +x "${MOCK_BIN}"/*

PATH="${MOCK_BIN}:${PATH}" \
  "${ROOT_DIR}/scripts/init_security_tooling.sh" --root "${ALT_ROOT}" >"${OUTPUT_FILE}"

assert_contains "${OUTPUT_FILE}" "Refreshing ClamAV signatures"
assert_contains "${OUTPUT_FILE}" "Initializing AIDE database"
assert_contains "${OUTPUT_FILE}" "Activated AIDE database: ${ALT_ROOT}/var/lib/aide/aide.db.gz"
assert_contains "${OUTPUT_FILE}" "OpenSCAP datastream present: ${ALT_ROOT}/usr/share/xml/scap/ssg/content/ssg-fedora-ds.xml"
assert_file_exists "${ALT_ROOT}/var/lib/aide/aide.db.gz"
assert_file_not_exists "${ALT_ROOT}/var/lib/aide/aide.db.new.gz"
