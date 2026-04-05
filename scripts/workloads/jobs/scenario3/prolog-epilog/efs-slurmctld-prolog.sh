#!/bin/bash
# =============================================================================
# efs-slurmctld-prolog.sh — SlurmctldProlog for ephemeral EFS
#
# Referenced in slurm.conf (combined with FSx prolog by Terraform):
#   SlurmctldProlog=/opt/slurm/etc/scripts/storage-slurmctld-prolog.sh
#   PrologEpilogTimeout=1800
#
# Trigger: #SBATCH --comment=efs
#
# EFS is available in ~60 seconds — the job will briefly appear in CF state
# before being released to run.
# =============================================================================

set -euo pipefail

# Not an EFS job
if [[ "${SLURM_JOB_COMMENT:-}" != "efs" ]]; then
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

: "${BURST_SUBNET_ID:?BURST_SUBNET_ID not set. Check /etc/sysconfig/burstlab-workloads}"
: "${EFS_SG_ID:?EFS_SG_ID not set. Check /etc/sysconfig/burstlab-workloads}"

export AWS_REGION BURST_SUBNET_ID EFS_SG_ID

# ---------------------------------------------------------------------------
# Create EFS filesystem (~60 seconds)
# ---------------------------------------------------------------------------
source /opt/slurm/etc/workloads/lib/efs-lifecycle.sh

GRANULARITY="${GRANULARITY:-per-job}"
CAMPAIGN_NAME="${CAMPAIGN_NAME:-default}"
JOB_REF="${SLURM_JOB_ID}"
export GRANULARITY CAMPAIGN_NAME JOB_REF

EFS_ID=$(efs_create "${JOB_REF}")
efs_add_mount_target "${EFS_ID}" "${BURST_SUBNET_ID}" "${EFS_SG_ID}"
efs_wait_available "${EFS_ID}"
efs_wait_mount_target "${EFS_ID}"
EFS_DNS="${EFS_ID}.efs.${AWS_REGION}.amazonaws.com"

# Write state file
STATE_DIR=$(eval echo "~${SLURM_JOB_USER}/.efs-state")
mkdir -p "${STATE_DIR}"
chmod 755 "${STATE_DIR}"
STATE_FILE="${STATE_DIR}/job-${SLURM_JOB_ID}.env"
cat > "${STATE_FILE}" << EOF
EFS_ID=${EFS_ID}
EFS_DNS=${EFS_DNS}
AWS_REGION=${AWS_REGION}
BURST_SUBNET_ID=${BURST_SUBNET_ID}
EFS_SG_ID=${EFS_SG_ID}
CREATED_BY_JOB=${JOB_REF}
GRANULARITY=${GRANULARITY}
CAMPAIGN_NAME=${CAMPAIGN_NAME}
EOF
chown "${SLURM_JOB_UID}" "${STATE_FILE}" 2>/dev/null || true
chmod 644 "${STATE_FILE}"

# Inject into job environment
SLURM_BIN=/opt/slurm/bin
"${SLURM_BIN}/scontrol" update \
  JobId="${SLURM_JOB_ID}" \
  Environment="EFS_STATE_FILE=${STATE_FILE}" 2>/dev/null || {
    echo "export EFS_STATE_FILE=${STATE_FILE}" \
      > "/tmp/slurm-efs-env-${SLURM_JOB_ID}.sh"
    chmod 644 "/tmp/slurm-efs-env-${SLURM_JOB_ID}.sh"
    echo "WARNING: scontrol update Environment failed; env file at /tmp" >&2
}

echo "EFS prolog complete: ${EFS_ID} → ${STATE_FILE}"
exit 0
