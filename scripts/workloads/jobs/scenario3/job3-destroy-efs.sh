#!/bin/bash
# =============================================================================
# scenario3/job3-destroy-efs.sh — Destroy ephemeral EFS filesystem
#
# Reads the EFS ID from the state file written by Job 1, destroys the mount
# targets and the filesystem, then removes the state file.
#
# Runs after Job 2 (--dependency=afterok) so the filesystem is unmounted
# before deletion. For per-campaign granularity, this job is NOT submitted
# automatically — the SA destroys the filesystem manually when the campaign ends.
#
# SA talking point: "Job 3 destroys the EFS filesystem completely — mount
# targets first, then the filesystem itself. Watch the AWS console: the
# filesystem disappears. The cluster's permanent EFS is untouched. Cost
# was only for the duration of Job 2."
# =============================================================================

#SBATCH --job-name=efs-destroy
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:10:00
#SBATCH --output=/u/home/alice/logs/efs-destroy-%j.out
#SBATCH --error=/u/home/alice/logs/efs-destroy-%j.err

set -euo pipefail
mkdir -p /u/home/alice/logs

source /opt/slurm/etc/workloads/lib/efs-lifecycle.sh

echo "=== EFS Destroy: started on $(hostname): $(date) ==="
echo "  Job ID:      ${SLURM_JOB_ID}"
echo "  Granularity: ${GRANULARITY}"

# Locate the state file written by Job 1
STATE_FILE=$(resolve_state_file "${GRANULARITY}" "${CAMPAIGN_NAME:-default}")
echo "  State file:  ${STATE_FILE}"

if [ ! -f "${STATE_FILE}" ]; then
  echo "ERROR: State file not found: ${STATE_FILE}" >&2
  echo "Nothing to destroy — EFS may have already been cleaned up." >&2
  exit 0
fi

# shellcheck source=/dev/null
source "${STATE_FILE}"
echo "  EFS ID:      ${EFS_ID}"
echo "  Created by:  Job ${CREATED_BY_JOB:-unknown}"

# Confirm the filesystem still exists before attempting deletion
CURRENT_STATE=$(aws efs describe-file-systems \
  --file-system-id "${EFS_ID}" \
  --region "${AWS_REGION}" \
  --query 'FileSystems[0].LifeCycleState' \
  --output text 2>/dev/null || echo "not-found")

if [ "$CURRENT_STATE" = "not-found" ] || [ "$CURRENT_STATE" = "None" ]; then
  echo "EFS ${EFS_ID} not found — already deleted. Cleaning up state file."
  rm -f "${STATE_FILE}"
  exit 0
fi

echo "  Current state: ${CURRENT_STATE}"

# Destroy the filesystem (mount targets first, then filesystem)
echo ""
echo "Destroying EFS ${EFS_ID}..."
efs_destroy "${EFS_ID}"

# Remove the state file so per-campaign modes don't reuse a stale ID
echo "Removing state file: ${STATE_FILE}"
rm -f "${STATE_FILE}"

echo ""
echo "=== EFS Destroy: COMPLETE ==="
echo "  EFS ${EFS_ID} deleted."
echo "  Completed: $(date)"
