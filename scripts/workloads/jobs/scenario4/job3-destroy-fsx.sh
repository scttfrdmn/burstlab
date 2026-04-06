#!/bin/bash
# =============================================================================
# scenario4/job3-destroy-fsx.sh — Flush results to S3 and destroy FSx Lustre
#
# Reads the FSx ID from the state file written by Job 1, creates an S3 export
# data repository task to flush results from FSx back to S3, waits for the
# export to complete, then destroys the FSx filesystem.
#
# This is the key "cloud native" moment: results live in FSx during the job,
# then are durably flushed to S3 before the filesystem disappears.
#
# SA talking point: "Job 3 is where cloud-native data management pays off.
# It flushes the output files from FSx back to S3 using a data repository task.
# Once the export completes, the FSx filesystem is deleted. The results are
# safely in S3 at ~$0.023/GB-month — 6x cheaper than keeping them on FSx.
# Watch the FSx console: the filesystem disappears."
# =============================================================================

#SBATCH --job-name=fsx-destroy
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:20:00
#SBATCH --output=/home/alice/logs/fsx-destroy-%j.out
#SBATCH --error=/home/alice/logs/fsx-destroy-%j.err

set -euo pipefail
mkdir -p /home/alice/logs

source /opt/slurm/etc/workloads/lib/fsx-lifecycle.sh

echo "=== FSx Destroy: started on $(hostname): $(date) ==="
echo "  Job ID:      ${SLURM_JOB_ID}"
echo "  Granularity: ${GRANULARITY}"

# Locate the state file (passed explicitly by submit-chain.sh, or derived)
STATE_FILE="${FSX_STATE_FILE:-$(resolve_fsx_state_file "${GRANULARITY}" "${CAMPAIGN_NAME:-default}")}"
echo "  State file:  ${STATE_FILE}"

if [ ! -f "${STATE_FILE}" ]; then
  echo "ERROR: State file not found: ${STATE_FILE}" >&2
  echo "Nothing to destroy — FSx may have already been cleaned up." >&2
  exit 0
fi

# shellcheck source=/dev/null
source "${STATE_FILE}"
echo "  FSx ID:      ${FSX_ID}"
echo "  S3 bucket:   ${S3_DATA_BUCKET}"
echo "  S3 prefix:   ${S3_PREFIX}"
echo "  Created by:  Job ${CREATED_BY_JOB:-unknown}"

# Confirm the filesystem still exists before attempting export/deletion
CURRENT_STATE=$(aws fsx describe-file-systems \
  --file-system-ids "${FSX_ID}" \
  --region "${AWS_REGION}" \
  --query 'FileSystems[0].Lifecycle' \
  --output text 2>/dev/null || echo "not-found")

if [ "$CURRENT_STATE" = "not-found" ] || [ "$CURRENT_STATE" = "None" ]; then
  echo "FSx ${FSX_ID} not found — already deleted. Cleaning up state file."
  rm -f "${STATE_FILE}"
  exit 0
fi

echo "  Current state: ${CURRENT_STATE}"

# Flush results from FSx back to S3 via data repository export task
# This ensures output files written during Job 2 are durably persisted to S3.
echo ""
echo "Flushing results from FSx to s3://${S3_DATA_BUCKET}/${S3_PREFIX}/output/..."
TASK_ID=$(fsx_flush_to_s3 "${FSX_ID}" "output/")

if [ -n "${TASK_ID}" ]; then
  echo "  Export task: ${TASK_ID}"
  fsx_wait_export "${FSX_ID}" "${TASK_ID}"

  # Confirm results landed in S3
  RESULT_COUNT=$(aws s3 ls "s3://${S3_DATA_BUCKET}/${S3_PREFIX}/output/" \
    --recursive --region "${AWS_REGION}" 2>/dev/null | wc -l || echo 0)
  echo "  Objects in S3 output: ${RESULT_COUNT}"
  echo "  S3 path: s3://${S3_DATA_BUCKET}/${S3_PREFIX}/output/"
else
  echo "WARNING: Could not create export task — proceeding with destruction anyway."
  echo "Results on permanent EFS (/home/alice/results/) are still intact."
fi

# Copy results to the durable results bucket (if configured)
RESULTS_BUCKET="${RESULTS_BUCKET:-}"
# Use the workload job's Slurm ID as history key so fsx-list shows the
# correct ~/results/fsx-job-<N>-task-0/ path that job2 wrote.
# WORKLOAD_JOB_ID is appended to the state file by job2 at runtime.
# Falls back to CREATED_BY_JOB (chain: job1's Slurm ID) or this job's ID.
HISTORY_KEY="${WORKLOAD_JOB_ID:-${CREATED_BY_JOB:-${SLURM_JOB_ID}}}"
HISTORY_LABEL="${CAMPAIGN_NAME:-default}"
if [ -n "${RESULTS_BUCKET}" ]; then
  echo ""
  echo "Copying results to durable bucket: s3://${RESULTS_BUCKET}/runs/${HISTORY_KEY}/"
  aws s3 sync \
    "s3://${S3_DATA_BUCKET}/${S3_PREFIX}/output/" \
    "s3://${RESULTS_BUCKET}/runs/${HISTORY_KEY}/" \
    --region "${AWS_REGION}" --quiet || \
    echo "WARNING: Copy to results bucket failed — results still in data bucket." >&2
fi

# Destroy the FSx filesystem
echo ""
echo "Destroying FSx filesystem ${FSX_ID}..."
fsx_destroy "${FSX_ID}"

# Write run record (persists on permanent EFS for fsx-list / fsx-restore)
HISTORY_DIR="/home/alice/.fsx-history"
mkdir -p "${HISTORY_DIR}"
HISTORY_FILE="${HISTORY_DIR}/${HISTORY_KEY}.run"
cat > "${HISTORY_FILE}" << EOF
# BurstLab FSx run record — written $(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_ID=${HISTORY_KEY}
LABEL=${HISTORY_LABEL}
S3_DATA_BUCKET=${S3_DATA_BUCKET}
S3_PREFIX=${S3_PREFIX}
S3_OUTPUT_URI=s3://${S3_DATA_BUCKET}/${S3_PREFIX}/output/
RESULTS_BUCKET=${RESULTS_BUCKET:-none}
RESULTS_URI=${RESULTS_BUCKET:+s3://${RESULTS_BUCKET}/runs/${HISTORY_KEY}/}
EFS_RESULTS=~/results/fsx-job-${HISTORY_KEY}-task-0
BURST_SUBNET_ID=${BURST_SUBNET_ID:-}
FSX_SG_ID=${FSX_SG_ID:-}
AWS_REGION=${AWS_REGION}
FSX_STORAGE_GB=${FSX_STORAGE_GB:-1200}
COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# Remove the state file
rm -f "${STATE_FILE}"

echo ""
echo "=== FSx Destroy: COMPLETE ==="
echo "  FSx ${FSX_ID} deleted."
echo "  Results on EFS:  ~/results/fsx-job-${HISTORY_KEY}-task-0/"
echo "  Results in S3:   s3://${S3_DATA_BUCKET}/${S3_PREFIX}/output/"
if [ -n "${RESULTS_BUCKET}" ]; then
  echo "  Durable copy:    s3://${RESULTS_BUCKET}/runs/${HISTORY_KEY}/"
fi
echo ""
echo "  View past runs:  fsx-list"
echo "  Restore data:    fsx-restore ${HISTORY_KEY}"
echo "  Clean up S3:     fsx-purge ${HISTORY_KEY}"
echo "  Completed: $(date)"
