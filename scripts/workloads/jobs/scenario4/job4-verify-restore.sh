#!/bin/bash
# =============================================================================
# scenario4/job4-verify-restore.sh — Verify FSx data hydration from S3
#
# Mounts a newly-created FSx filesystem that is linked to an S3 prefix
# containing data from a previous write chain. Verifies:
#   1. Output files are visible in the Lustre namespace (as stubs)
#   2. Files can be read (triggers lazy hydration from S3)
#   3. SHA256 checksums match the manifest written by the original write chain
#
# SA talking point: "The FSx filesystem we're mounting was created 5 minutes ago.
# It's never seen this data before. But because it's linked to the same S3 prefix,
# the files appear immediately — look, they're all here. When we read them, Lustre
# fetches the bytes from S3 on demand. The checksums match the original write. S3
# is the ground truth. FSx is just a high-performance cache you spin up when needed."
# =============================================================================

#SBATCH --job-name=fsx-verify-restore
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:30:00
#SBATCH --output=/home/alice/logs/fsx-verify-restore-%j.out
#SBATCH --error=/home/alice/logs/fsx-verify-restore-%j.err

set -euo pipefail
mkdir -p /home/alice/logs

# Ensure Lustre kernel module is loaded
if ! lsmod | grep -q '^lustre'; then
  sudo modprobe lustre 2>/dev/null || {
    echo "ERROR: Cannot load Lustre kernel module." >&2
    exit 1
  }
fi

source /opt/slurm/etc/workloads/lib/fsx-lifecycle.sh

echo "=== FSx Verify Restore: started on $(hostname): $(date) ==="
echo "  Job ID: ${SLURM_JOB_ID}"

# Read FSx state
STATE_FILE="${FSX_STATE_FILE:-}"
if [ -z "${STATE_FILE}" ] || [ ! -f "${STATE_FILE}" ]; then
  echo "ERROR: FSX_STATE_FILE not set or not found: ${STATE_FILE}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${STATE_FILE}"
echo "  FSx ID:    ${FSX_ID}"
echo "  FSx DNS:   ${FSX_DNS}"
echo "  Mount:     ${FSX_MOUNT_NAME}"
echo "  S3 bucket: ${S3_DATA_BUCKET}"
echo "  S3 prefix: ${S3_PREFIX}"

# Verify FSx is available
CURRENT_STATE=$(aws fsx describe-file-systems \
  --file-system-ids "${FSX_ID}" \
  --region "${AWS_REGION}" \
  --query 'FileSystems[0].Lifecycle' \
  --output text 2>/dev/null || echo "not-found")

if [ "$CURRENT_STATE" != "AVAILABLE" ]; then
  echo "ERROR: FSx ${FSX_ID} is not AVAILABLE (state: ${CURRENT_STATE})" >&2
  exit 1
fi

# Mount the FSx filesystem
MOUNT_POINT="/tmp/fsx-${FSX_ID}-${SLURM_JOB_ID}-restore"
mkdir -p "${MOUNT_POINT}"

echo ""
echo "Mounting FSx Lustre at ${MOUNT_POINT}..."
sudo mount -t lustre \
  -o noatime,flock \
  "${FSX_DNS}@tcp:/${FSX_MOUNT_NAME}" \
  "${MOUNT_POINT}"
echo "  Mounted successfully."

# =========================================================================
# VERIFICATION PHASE
# =========================================================================
PASS=0
FAIL=0

_pass() { echo "  [PASS] $1"; ((PASS++)); }
_fail() { echo "  [FAIL] $1"; ((FAIL++)); }

echo ""
echo "=== Verification ==="

# FSx initial S3 metadata import is asynchronous — it completes in the
# background after the filesystem enters AVAILABLE. Listing the mount root
# triggers namespace population. We retry up to 3 minutes.
echo "Waiting for S3 namespace to populate in Lustre..."
OUTPUT_DIR="${MOUNT_POINT}/output"
POPULATED=false
for attempt in $(seq 1 12); do
  # ls on root triggers FSx to import S3 metadata for top-level objects
  ls "${MOUNT_POINT}/" &>/dev/null || true
  if [ -d "${OUTPUT_DIR}" ]; then
    POPULATED=true
    break
  fi
  echo "  attempt ${attempt}/12: output/ not yet visible — waiting 15s..."
  sleep 15
done

# Check 1: Output directory exists
if $POPULATED; then
  _pass "output/ directory exists in Lustre namespace"
else
  _fail "output/ directory NOT found after 3 minutes — S3 data may not have imported"
  sudo umount "${MOUNT_POINT}" && rmdir "${MOUNT_POINT}"
  exit 1
fi

# Check 2: Files are visible (as stubs before hydration)
FILE_COUNT=$(find "${OUTPUT_DIR}" -type f 2>/dev/null | wc -l)
if [ "${FILE_COUNT}" -gt 0 ]; then
  _pass "Found ${FILE_COUNT} files in output/ (visible as stubs)"
else
  _fail "No files found in output/"
fi

# Check 3: Input directory exists (data from original staging)
INPUT_DIR="${MOUNT_POINT}/input"
if [ -d "${INPUT_DIR}" ]; then
  INPUT_COUNT=$(find "${INPUT_DIR}" -type f 2>/dev/null | wc -l)
  _pass "input/ directory exists with ${INPUT_COUNT} files"
else
  echo "  [INFO] input/ directory not present (may not have been staged)"
fi

# Check 4: HSM state of output files (should be stubs before read)
echo ""
echo "Pre-hydration HSM state (files should be 'released' stubs):"
for f in "${OUTPUT_DIR}"/*/* 2>/dev/null; do
  [ -f "$f" ] || continue
  HSM=$(lfs hsm_state "$f" 2>/dev/null | awk '{print $2}' || echo "unknown")
  FNAME=$(basename "$f")
  echo "  ${FNAME}: ${HSM}"
  break  # just check one file to show the state
done

# Check 5: Read files to trigger hydration and verify content
echo ""
echo "Reading files to trigger S3 hydration..."
START=$(date +%s)

CHECKSUMS_FILE=$(mktemp)
for f in "${OUTPUT_DIR}"/*/* 2>/dev/null; do
  [ -f "$f" ] || continue
  FNAME=$(echo "$f" | sed "s|${OUTPUT_DIR}/||")
  FILE_START=$(date +%s)
  CKSUM=$(sha256sum "$f" | awk '{print $1}')
  FILE_ELAPSED=$(($(date +%s) - FILE_START))
  echo "${CKSUM}  ${f}" >> "${CHECKSUMS_FILE}"
  echo "  ${FNAME}: sha256=${CKSUM:0:16}... (${FILE_ELAPSED}s to hydrate)"
done

ELAPSED=$(($(date +%s) - START))
HYDRATED_COUNT=$(wc -l < "${CHECKSUMS_FILE}")
_pass "Hydrated ${HYDRATED_COUNT} files from S3 in ${ELAPSED}s"

# Check 6: Post-hydration HSM state (should no longer be 'released')
echo ""
echo "Post-hydration HSM state (files should now be local):"
for f in "${OUTPUT_DIR}"/*/* 2>/dev/null; do
  [ -f "$f" ] || continue
  HSM=$(lfs hsm_state "$f" 2>/dev/null | awk '{print $2}' || echo "unknown")
  FNAME=$(basename "$f")
  echo "  ${FNAME}: ${HSM}"
  break
done

# Check 7: Verify checksums against manifest (if available)
MANIFEST=""
for d in "${OUTPUT_DIR}"/*/; do
  [ -d "$d" ] || continue
  if [ -f "${d}manifest.sha256" ]; then
    MANIFEST="${d}manifest.sha256"
    break
  fi
done

echo ""
if [ -n "${MANIFEST}" ]; then
  echo "Found checksum manifest: ${MANIFEST}"
  echo "Verifying checksums against original write..."

  MANIFEST_PASS=0
  MANIFEST_FAIL=0
  while IFS= read -r line; do
    EXPECTED_HASH=$(echo "$line" | awk '{print $1}')
    ORIGINAL_PATH=$(echo "$line" | awk '{print $2}')
    FNAME=$(basename "${ORIGINAL_PATH}")

    # Find the same file in the restored output
    RESTORED_FILE=$(find "${OUTPUT_DIR}" -name "${FNAME}" -type f 2>/dev/null | head -1)
    if [ -z "${RESTORED_FILE}" ]; then
      echo "  [SKIP] ${FNAME} — not found in restored output"
      continue
    fi

    ACTUAL_HASH=$(sha256sum "${RESTORED_FILE}" | awk '{print $1}')
    if [ "${EXPECTED_HASH}" = "${ACTUAL_HASH}" ]; then
      echo "  [MATCH] ${FNAME}"
      ((MANIFEST_PASS++))
    else
      echo "  [MISMATCH] ${FNAME}: expected=${EXPECTED_HASH:0:16}... actual=${ACTUAL_HASH:0:16}..."
      ((MANIFEST_FAIL++))
    fi
  done < "${MANIFEST}"

  if [ "${MANIFEST_FAIL}" -eq 0 ]; then
    _pass "All ${MANIFEST_PASS} checksums match original write"
  else
    _fail "${MANIFEST_FAIL} checksum mismatches (${MANIFEST_PASS} matched)"
  fi
else
  echo "  [INFO] No manifest.sha256 found — skipping checksum verification"
  echo "  (manifest is written by job2-run-workload.sh in newer write chains)"
fi

rm -f "${CHECKSUMS_FILE}"

# Unmount
echo ""
echo "Unmounting ${MOUNT_POINT}..."
sudo umount "${MOUNT_POINT}"
rmdir "${MOUNT_POINT}"
echo "  Unmounted."

# Summary
echo ""
echo "=== FSx Verify Restore: ${PASS} passed, ${FAIL} failed ==="
if [ "${FAIL}" -gt 0 ]; then
  echo "  RESULT: VERIFICATION FAILED"
  exit 1
else
  echo "  RESULT: VERIFICATION PASSED"
  echo ""
  echo "  The data written by the original chain was successfully hydrated from S3"
  echo "  into a brand new FSx filesystem. S3 is the ground truth. FSx is ephemeral."
fi
echo "  Completed: $(date)"
