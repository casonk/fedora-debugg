#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/assert.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FAKE_ROOT="${TMP_DIR}/repo"
FAKE_SCRIPTS="${FAKE_ROOT}/scripts"
FAKE_ARTIFACTS="${FAKE_ROOT}/artifacts"
SNAPSHOT_DIR="${FAKE_ARTIFACTS}/snapshot-20260104-040506"
mkdir -p "${FAKE_SCRIPTS}" "${SNAPSHOT_DIR}/commands"

cp "${ROOT_DIR}/scripts/run_workflow.sh" "${FAKE_SCRIPTS}/run_workflow.sh"

cat >"${FAKE_SCRIPTS}/collect_snapshot.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${SNAPSHOT_DIR}/commands"
printf '%s\n' "${SNAPSHOT_DIR}"
EOF

cat >"${FAKE_SCRIPTS}/run_gpu_pcie_load_probe.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat >"${FAKE_SCRIPTS}/analyze_security_posture.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
report_dir=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --report-dir)
      report_dir="\$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
mkdir -p "\${report_dir}/tables"
printf 'ok\n' >"\${report_dir}/security-summary.md"
printf '%s\n' "\${report_dir}"
EOF

cat >"${FAKE_SCRIPTS}/analyze_snapshot.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
snapshot_dir="\$1"
[ -f "\${snapshot_dir}/security-posture/security-summary.md" ] || exit 91
printf '# Crash Analysis Summary\n' >"\${snapshot_dir}/analysis-summary.md"
EOF

cat >"${FAKE_SCRIPTS}/export_tachometer_signals.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
snapshot_dir=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --snapshot-dir)
      snapshot_dir="\$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -f "\${snapshot_dir}/security-posture/security-summary.md" ] || exit 92
printf '{}\n' >"\${snapshot_dir}/tachometer-signals.json"
printf '%s\n' "\${snapshot_dir}/tachometer-signals.json"
EOF

cat >"${FAKE_SCRIPTS}/archive_snapshots.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'rotation ok\n'
EOF

chmod +x "${FAKE_SCRIPTS}"/*.sh

OUTPUT_FILE="${TMP_DIR}/run_workflow.out"
"${FAKE_SCRIPTS}/run_workflow.sh" >"${OUTPUT_FILE}"

assert_contains "${OUTPUT_FILE}" "Snapshot: ${SNAPSHOT_DIR}"
assert_contains "${OUTPUT_FILE}" "Security posture: ${SNAPSHOT_DIR}/security-posture"
assert_contains "${OUTPUT_FILE}" "Tachometer sidecar: ${SNAPSHOT_DIR}/tachometer-signals.json"
assert_contains "${OUTPUT_FILE}" "Latest summary: ${SNAPSHOT_DIR}/analysis-summary.md"
assert_file_exists "${SNAPSHOT_DIR}/security-posture/security-summary.md"
assert_file_exists "${SNAPSHOT_DIR}/analysis-summary.md"
assert_file_exists "${SNAPSHOT_DIR}/tachometer-signals.json"
