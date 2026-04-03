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
#SBATCH --output=/u/home/alice/logs/fsx-destroy-%j.out
#SBATCH --error=/u/home/alice/logs/fsx-destroy-%j.err

set -euo pipefail
mkdir -p /u/home/alice/logs

source /opt/slurm/etc/workloads/lib/fsx-lifecycle.sh

echo "=== FSx Destroy: started on $(hostname): $(date) ==="
echo "  Job ID:      ${SLURM_JOB_ID}"
echo "  Granularity: ${GRANULARITY}"

# Locate the state file written by Job 1
STATE_FILE=$(resolve_fsx_state_file "${GRANULARITY}" "${CAMPAIGN_NAME:-default}")
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
  echo "Results on permanent EFS (/u/home/alice/results/) are still intact."
fi

# Destroy the FSx filesystem
echo ""
echo "Destroying FSx filesystem ${FSX_ID}..."
fsx_destroy "${FSX_ID}"

# Remove the state file
echo "Removing state file: ${STATE_FILE}"
rm -f "${STATE_FILE}"

echo ""
echo "=== FSx Destroy: COMPLETE ==="
echo "  FSx ${FSX_ID} deleted."
echo "  Results persisted at: s3://${S3_DATA_BUCKET}/${S3_PREFIX}/output/"
echo "  S3 cost:   ~\$0.023/GB-month (vs \$0.14/GB-month on FSx)"
echo "  Completed: $(date)"
