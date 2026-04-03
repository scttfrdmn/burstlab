#!/bin/bash
# =============================================================================
# scenario4/job2-run-workload.sh — Mount ephemeral FSx Lustre and run workload
#
# Reads the FSx ID and DNS from the state file written by Job 1, mounts the
# Lustre filesystem, runs the workload (data hydrates lazily from S3 on first
# read), writes results to FSx, then unmounts.
#
# Lazy hydration: files appear immediately in the Lustre namespace (as stubs)
# but are only transferred from S3 when the application first reads them.
# This is what makes FSx Lustre "cloud native" — no pre-copy needed.
#
# SA talking point: "Job 2 mounts the FSx filesystem and opens an input file.
# That file isn't physically on FSx yet — it's a stub linked to S3. Lustre
# hydrates it on demand, streaming from S3 at full filesystem bandwidth.
# The application has no idea it's reading from S3."
# =============================================================================

#SBATCH --job-name=fsx-workload
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --time=01:00:00
#SBATCH --output=/u/home/alice/logs/fsx-workload-%j.out
#SBATCH --error=/u/home/alice/logs/fsx-workload-%j.err

set -euo pipefail
mkdir -p /u/home/alice/logs

source /opt/slurm/etc/workloads/lib/fsx-lifecycle.sh

echo "=== FSx Workload: started on $(hostname): $(date) ==="
echo "  Job ID:         ${SLURM_JOB_ID}"
echo "  Array Task ID:  ${SLURM_ARRAY_TASK_ID:-none}"
echo "  Granularity:    ${GRANULARITY}"

# Read FSx state from file written by Job 1
STATE_FILE=$(resolve_fsx_state_file "${GRANULARITY}" "${CAMPAIGN_NAME:-default}")
echo "  State file:     ${STATE_FILE}"

if [ ! -f "${STATE_FILE}" ]; then
  echo "ERROR: State file not found: ${STATE_FILE}" >&2
  echo "Did Job 1 complete successfully?" >&2
  exit 1
fi

source "${STATE_FILE}"
echo "  FSx ID:         ${FSX_ID}"
echo "  FSx DNS:        ${FSX_DNS}"
echo "  Mount name:     ${FSX_MOUNT_NAME}"
echo "  S3 bucket:      ${S3_DATA_BUCKET}"
echo "  S3 prefix:      ${S3_PREFIX}"

# Verify FSx is still available
CURRENT_STATE=$(aws fsx describe-file-systems \
  --file-system-ids "${FSX_ID}" \
  --region "${AWS_REGION}" \
  --query 'FileSystems[0].Lifecycle' \
  --output text 2>/dev/null || echo "not-found")

if [ "$CURRENT_STATE" != "AVAILABLE" ]; then
  echo "ERROR: FSx ${FSX_ID} is not AVAILABLE (current state: ${CURRENT_STATE})" >&2
  exit 1
fi

# Mount the FSx Lustre filesystem
TASK_ID="${SLURM_ARRAY_TASK_ID:-0}"
MOUNT_POINT="/mnt/scratch/fsx-${FSX_ID}-${SLURM_JOB_ID}-${TASK_ID}"
mkdir -p "${MOUNT_POINT}"

echo ""
echo "Mounting FSx Lustre at ${MOUNT_POINT}..."
mount -t lustre \
  -o noatime,flock \
  "${FSX_DNS}@tcp:/${FSX_MOUNT_NAME}" \
  "${MOUNT_POINT}"

echo "  Mounted successfully."

# Lustre client tuning for burst nodes (write-heavy workloads)
lctl set_param osc.*.max_rpcs_in_flight=16 2>/dev/null || true
lctl set_param osc.*.max_pages_per_rpc=256 2>/dev/null || true

# Set up per-task directories
INPUT_DIR="${MOUNT_POINT}/input"
OUTPUT_DIR="${MOUNT_POINT}/output/${TASK_ID}"
mkdir -p "${OUTPUT_DIR}"

# Files in INPUT_DIR are stubs — they hydrate from S3 on first read
echo ""
echo "Input files in Lustre namespace (stubs, hydrate on read):"
ls -lh "${INPUT_DIR}/" 2>/dev/null | head -10 || echo "  (no files yet — checking S3 import)"

# Trigger file listing to force HSM import of the input directory
lfs hsm_state "${INPUT_DIR}"/* 2>/dev/null | head -5 || true

# Run workload — this triggers lazy hydration for each file read
echo ""
echo "Running workload (lazy hydration from S3 on first read)..."
START=$(date +%s)

for f in "${INPUT_DIR}"/*; do
  [ -f "$f" ] || continue
  FNAME=$(basename "$f")

  # Reading the file triggers S3 hydration if not yet local
  FILE_START=$(date +%s)
  CKSUM=$(md5sum "$f" | awk '{print $1}')
  FILE_ELAPSED=$(($(date +%s) - FILE_START))

  echo "${FNAME}: ${CKSUM} (${FILE_ELAPSED}s to read)" >> "${OUTPUT_DIR}/checksums.txt"

  # Check if file is now fully hydrated
  HSM_STATE=$(lfs hsm_state "$f" 2>/dev/null | awk '{print $2}' || echo "unknown")
  echo "  ${FNAME}: checksum=${CKSUM}, hsm=${HSM_STATE}, read=${FILE_ELAPSED}s"
done

# Write job metadata
cat > "${OUTPUT_DIR}/job-metadata.txt" << EOF
Job ID:       ${SLURM_JOB_ID}
Array Task:   ${SLURM_ARRAY_TASK_ID:-none}
Node:         $(hostname)
FSx ID:       ${FSX_ID}
S3 bucket:    ${S3_DATA_BUCKET}
S3 prefix:    ${S3_PREFIX}
Started:      $(date -u +%Y-%m-%dT%H:%M:%SZ)
Granularity:  ${GRANULARITY}
EOF

ELAPSED=$(($(date +%s) - START))
echo "  Workload completed in ${ELAPSED}s"
OUTPUT_COUNT=$(ls "${OUTPUT_DIR}/" 2>/dev/null | wc -l)
echo "  Output: ${OUTPUT_COUNT} files in ${OUTPUT_DIR}"

# Copy results to permanent EFS as well
RESULTS_DIR="/u/home/alice/results/fsx-job-${SLURM_JOB_ID}-task-${TASK_ID}"
mkdir -p "${RESULTS_DIR}"
cp -r "${OUTPUT_DIR}"/. "${RESULTS_DIR}/"
echo "  Results mirrored to permanent EFS: ${RESULTS_DIR}"

# Unmount before Job 3 flushes and destroys the filesystem
echo ""
echo "Unmounting ${MOUNT_POINT}..."
umount "${MOUNT_POINT}"
rmdir "${MOUNT_POINT}"
echo "  Unmounted."

echo ""
echo "=== FSx Workload: COMPLETE ==="
echo "  Elapsed:   ${ELAPSED}s"
echo "  Results:   ${RESULTS_DIR} (permanent EFS)"
echo "  FSx path:  ${OUTPUT_DIR} (pending flush to S3 by Job 3)"
echo "  Completed: $(date)"
