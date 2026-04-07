#!/bin/bash
# =============================================================================
# fsx-slurmctld-epilog.sh — EpilogSlurmctld for ephemeral FSx Lustre
#
# Referenced in slurm.conf:
#   EpilogSlurmctld=/opt/slurm/etc/scripts/storage-slurmctld-epilog.sh
#
# This script is combined with efs-slurmctld-epilog.sh into a single
# storage-slurmctld-epilog.sh by the Terraform module.
#
# Trigger: same as prolog — checks #SBATCH --comment=fsx:<GB>
#
# On success: exits 0.
# On non-zero exit: slurmctld logs an error but the job state is unchanged.
# =============================================================================

set -euo pipefail

export PATH="/usr/local/bin:${PATH}"

# Not an FSx job
if [[ ! "${SLURM_JOB_COMMENT:-}" =~ ^fsx: ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Source config
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-west-2)}"
if [ -f /etc/sysconfig/burstlab-workloads ]; then
  # shellcheck source=/dev/null
  source /etc/sysconfig/burstlab-workloads
fi

export AWS_REGION

source /opt/slurm/etc/workloads/lib/fsx-lifecycle.sh

# ---------------------------------------------------------------------------
# Find the state file for this job
# ---------------------------------------------------------------------------
STATE_FILE="/opt/slurm/var/fsx-state/${SLURM_JOB_USER}/job-${SLURM_JOB_ID}.env"

if [ ! -f "${STATE_FILE}" ]; then
  # Nothing to destroy — prolog may have failed before creating FSx
  echo "FSx epilog: no state file found for job ${SLURM_JOB_ID} — nothing to destroy"
  exit 0
fi

# shellcheck source=/dev/null
source "${STATE_FILE}"

# Confirm filesystem still exists
CURRENT_STATE=$(aws fsx describe-file-systems \
  --file-system-ids "${FSX_ID}" \
  --region "${AWS_REGION}" \
  --query 'FileSystems[0].Lifecycle' \
  --output text 2>/dev/null || echo "not-found")

if [ "$CURRENT_STATE" = "not-found" ] || [ "$CURRENT_STATE" = "None" ]; then
  echo "FSx epilog: ${FSX_ID} not found — already deleted"
  rm -f "${STATE_FILE}"
  exit 0
fi

echo "FSx epilog: flushing results to S3 and destroying ${FSX_ID}..."

# Flush output directory to S3
TASK_ID=$(fsx_flush_to_s3 "${FSX_ID}" "output/")
if [ -n "${TASK_ID}" ]; then
  fsx_wait_export "${FSX_ID}" "${TASK_ID}" || {
    echo "WARNING: export task did not complete cleanly — proceeding with destruction" >&2
  }
fi

fsx_destroy "${FSX_ID}"
rm -f "${STATE_FILE}"

echo "FSx epilog: ${FSX_ID} destroyed, state file removed"
exit 0
