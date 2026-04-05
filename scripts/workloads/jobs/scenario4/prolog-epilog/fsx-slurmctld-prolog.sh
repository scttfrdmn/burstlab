#!/bin/bash
# =============================================================================
# fsx-slurmctld-prolog.sh — SlurmctldProlog for ephemeral FSx Lustre
#
# Installed to /opt/slurm/etc/scripts/ and referenced in slurm.conf:
#   SlurmctldProlog=/opt/slurm/etc/scripts/storage-slurmctld-prolog.sh
#   PrologEpilogTimeout=1800
#
# This script (and efs-slurmctld-prolog.sh) are combined into a single
# storage-slurmctld-prolog.sh by the Terraform module. See:
#   terraform/workloads/scenario4-prolog-epilog/main.tf
#
# Trigger: #SBATCH --comment=fsx:<storage_gb>
#   Example: #SBATCH --comment=fsx:1200
#
# Slurm env vars available to SlurmctldProlog:
#   SLURM_JOB_ID, SLURM_JOB_COMMENT, SLURM_JOB_USER,
#   SLURM_JOB_PARTITION, SLURM_JOB_UID
#
# On success: exits 0. Slurm starts the job.
# On failure: exits non-zero. Slurm kills the job with reason "PrologFailed".
#
# SA talking point: "The user submits a completely standard sbatch command —
# the only change is #SBATCH --comment=fsx:1200. The cluster intercepts it
# here in the prolog, provisions FSx while the job sits in 'configuring'
# state, injects the filesystem path into the job environment, then releases
# it to run. The user doesn't know or care about the underlying mechanism."
# =============================================================================

set -euo pipefail

# Not an FSx job — exit immediately (no cost for normal jobs)
if [[ ! "${SLURM_JOB_COMMENT:-}" =~ ^fsx:([0-9]+)$ ]]; then
  exit 0
fi

FSX_STORAGE_GB="${BASH_REMATCH[1]}"

# ---------------------------------------------------------------------------
# Source required config from the job owner's environment profile
# AWS_REGION and storage parameters are set via /etc/profile.d/ or sysconfig
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-west-2)}"

# Required vars — written to /etc/sysconfig/burstlab by Terraform deploy
if [ -f /etc/sysconfig/burstlab-workloads ]; then
  # shellcheck source=/dev/null
  source /etc/sysconfig/burstlab-workloads
fi

: "${BURST_SUBNET_ID:?BURST_SUBNET_ID not set. Check /etc/sysconfig/burstlab-workloads}"
: "${FSX_SG_ID:?FSX_SG_ID not set. Check /etc/sysconfig/burstlab-workloads}"
: "${S3_DATA_BUCKET:?S3_DATA_BUCKET not set. Check /etc/sysconfig/burstlab-workloads}"

export AWS_REGION BURST_SUBNET_ID FSX_SG_ID S3_DATA_BUCKET FSX_STORAGE_GB

# ---------------------------------------------------------------------------
# Create FSx Lustre filesystem
# ---------------------------------------------------------------------------
source /opt/slurm/etc/workloads/lib/fsx-lifecycle.sh

GRANULARITY="${GRANULARITY:-per-job}"
CAMPAIGN_NAME="${CAMPAIGN_NAME:-default}"
JOB_REF="${SLURM_JOB_ID}"
S3_PREFIX="jobs/${JOB_REF}"
export GRANULARITY CAMPAIGN_NAME JOB_REF S3_PREFIX

# Stage synthetic input data into S3 (prolog runs as SlurmUser — no user data)
if [ -d "/opt/slurm/etc/workloads/data" ]; then
  aws s3 sync /opt/slurm/etc/workloads/data/ \
    "s3://${S3_DATA_BUCKET}/${S3_PREFIX}/input/" \
    --region "${AWS_REGION}" --quiet 2>/dev/null || true
fi

# Create and wait for FSx — this is what makes the job appear in "CF" state
FSX_ID=$(fsx_create "${JOB_REF}" "${S3_DATA_BUCKET}" "${S3_PREFIX}" \
  "${BURST_SUBNET_ID}" "${FSX_SG_ID}" "${FSX_STORAGE_GB}")
fsx_wait_available "${FSX_ID}"
FSX_DNS=$(fsx_get_dns "${FSX_ID}")
FSX_MOUNT_NAME=$(aws fsx describe-file-systems \
  --file-system-ids "${FSX_ID}" \
  --region "${AWS_REGION}" \
  --query 'FileSystems[0].LustreConfiguration.MountName' \
  --output text)

# Write state file (owned by the submitting user)
STATE_DIR=$(eval echo "~${SLURM_JOB_USER}/.fsx-state")
mkdir -p "${STATE_DIR}"
chmod 755 "${STATE_DIR}"
STATE_FILE="${STATE_DIR}/job-${SLURM_JOB_ID}.env"
cat > "${STATE_FILE}" << EOF
FSX_ID=${FSX_ID}
FSX_DNS=${FSX_DNS}
FSX_MOUNT_NAME=${FSX_MOUNT_NAME}
S3_DATA_BUCKET=${S3_DATA_BUCKET}
S3_PREFIX=${S3_PREFIX}
AWS_REGION=${AWS_REGION}
CREATED_BY_JOB=${JOB_REF}
GRANULARITY=${GRANULARITY}
CAMPAIGN_NAME=${CAMPAIGN_NAME}
EOF
chown "${SLURM_JOB_UID}" "${STATE_FILE}" 2>/dev/null || true
chmod 644 "${STATE_FILE}"

# ---------------------------------------------------------------------------
# Inject FSX_STATE_FILE into the job's environment
# Slurm 21.08+ supports: scontrol update JobId=N Environment="KEY=VAL"
# This appends to the job's existing environment (does not replace).
# ---------------------------------------------------------------------------
SLURM_BIN=/opt/slurm/bin
"${SLURM_BIN}/scontrol" update \
  JobId="${SLURM_JOB_ID}" \
  Environment="FSX_STATE_FILE=${STATE_FILE}" 2>/dev/null || {
    # Fallback: write to a per-job env file that the job script can source
    echo "export FSX_STATE_FILE=${STATE_FILE}" \
      > "/tmp/slurm-fsx-env-${SLURM_JOB_ID}.sh"
    chmod 644 "/tmp/slurm-fsx-env-${SLURM_JOB_ID}.sh"
    echo "WARNING: scontrol update Environment failed; env file written to /tmp" >&2
}

echo "FSx prolog complete: ${FSX_ID} → ${STATE_FILE}"
exit 0
