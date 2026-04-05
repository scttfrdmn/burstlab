#!/bin/bash
# =============================================================================
# efs-slurmctld-epilog.sh — SlurmctldEpilog for ephemeral EFS
#
# Referenced in slurm.conf (combined with FSx epilog by Terraform):
#   SlurmctldEpilog=/opt/slurm/etc/scripts/storage-slurmctld-epilog.sh
#
# Destroys the ephemeral EFS filesystem after the job completes.
# Results on permanent cluster EFS (/home/alice/results/) are preserved —
# no S3 flush needed (unlike FSx).
# =============================================================================

set -euo pipefail

# Not an EFS job
if [[ "${SLURM_JOB_COMMENT:-}" != "efs" ]]; then
  exit 0
fi

AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-west-2)}"
if [ -f /etc/sysconfig/burstlab-workloads ]; then
  # shellcheck source=/dev/null
  source /etc/sysconfig/burstlab-workloads
fi

export AWS_REGION

source /opt/slurm/etc/workloads/lib/efs-lifecycle.sh

STATE_FILE="$(eval echo "~${SLURM_JOB_USER}/.efs-state")/job-${SLURM_JOB_ID}.env"

if [ ! -f "${STATE_FILE}" ]; then
  echo "EFS epilog: no state file for job ${SLURM_JOB_ID} — nothing to destroy"
  exit 0
fi

# shellcheck source=/dev/null
source "${STATE_FILE}"

CURRENT_STATE=$(aws efs describe-file-systems \
  --file-system-id "${EFS_ID}" \
  --region "${AWS_REGION}" \
  --query 'FileSystems[0].LifeCycleState' \
  --output text 2>/dev/null || echo "not-found")

if [ "$CURRENT_STATE" = "not-found" ] || [ "$CURRENT_STATE" = "None" ]; then
  echo "EFS epilog: ${EFS_ID} not found — already deleted"
  rm -f "${STATE_FILE}"
  exit 0
fi

echo "EFS epilog: destroying ${EFS_ID}..."
efs_destroy "${EFS_ID}"
rm -f "${STATE_FILE}"

echo "EFS epilog: ${EFS_ID} destroyed"
exit 0
