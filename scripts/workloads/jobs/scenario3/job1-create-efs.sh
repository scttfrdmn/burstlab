#!/bin/bash
# =============================================================================
# scenario3/job1-create-efs.sh — Create ephemeral EFS filesystem
#
# Submitted by submit-chain.sh. Creates an EFS filesystem and mount target
# in the cloud subnet, then writes the filesystem ID to a state file on the
# permanent cluster EFS so Job 2 can find it.
#
# SA talking point: "Job 1 calls the AWS EFS API directly from the burst node
# to create a filesystem. Takes about 60 seconds to become available. The
# filesystem ID is written to the cluster's permanent EFS so the next job
# can pick it up — the state file is the handoff between jobs."
# =============================================================================

#SBATCH --job-name=efs-create
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:10:00
#SBATCH --output=/u/home/alice/logs/efs-create-%j.out
#SBATCH --error=/u/home/alice/logs/efs-create-%j.err

set -euo pipefail
mkdir -p /u/home/alice/logs

source /opt/slurm/etc/workloads/lib/efs-lifecycle.sh

echo "=== EFS Create: started on $(hostname): $(date) ==="
echo "  Job ID:     ${SLURM_JOB_ID}"
echo "  Granularity:${GRANULARITY}"
echo "  Subnet:     ${CLOUD_SUBNET_A_ID}"
echo "  SG:         ${EFS_SG_ID}"
echo "  Region:     ${AWS_REGION}"

# Determine state file location for this granularity mode
STATE_FILE=$(resolve_state_file "${GRANULARITY}" "${CAMPAIGN_NAME:-default}")
echo "  State file: ${STATE_FILE}"

# Check idempotency — don't create a second EFS if state file already exists
if [ -f "${STATE_FILE}" ]; then
  # shellcheck source=/dev/null
  source "${STATE_FILE}"
  echo "State file exists (EFS_ID=${EFS_ID:-unknown}) — checking if still valid..."
  EXISTING_STATE=$(aws efs describe-file-systems \
    --file-system-id "${EFS_ID:-none}" \
    --region "${AWS_REGION}" \
    --query 'FileSystems[0].LifeCycleState' \
    --output text 2>/dev/null || echo "not-found")

  if [ "$EXISTING_STATE" = "available" ]; then
    echo "Existing EFS ${EFS_ID} is still available — skipping creation."
    echo "To force recreate: rm ${STATE_FILE}"
    exit 0
  else
    echo "Existing EFS not found or not available — creating new one."
    rm -f "${STATE_FILE}"
  fi
fi

# Create the EFS filesystem
echo ""
echo "Creating EFS filesystem..."
EFS_ID=$(efs_create "${SLURM_JOB_ID}")
echo "  Created: ${EFS_ID}"

# Add mount target in the cloud subnet
echo "Adding mount target in ${CLOUD_SUBNET_A_ID}..."
MT_ID=$(efs_add_mount_target "${EFS_ID}" "${CLOUD_SUBNET_A_ID}" "${EFS_SG_ID}")
echo "  Mount target: ${MT_ID}"

# Wait for filesystem to be available
efs_wait_available "${EFS_ID}"

# Wait for mount target to be available
efs_wait_mount_target "${EFS_ID}"

# Write state file to permanent cluster EFS — Job 2 reads this
cat > "${STATE_FILE}" << EOF
# BurstLab ephemeral EFS state
# Created by Job ${SLURM_JOB_ID} at $(date -u +%Y-%m-%dT%H:%M:%SZ)
EFS_ID=${EFS_ID}
EFS_MT_ID=${MT_ID}
EFS_DNS=${EFS_ID}.efs.${AWS_REGION}.amazonaws.com
CREATED_BY_JOB=${SLURM_JOB_ID}
GRANULARITY=${GRANULARITY}
CAMPAIGN_NAME=${CAMPAIGN_NAME:-default}
EOF

echo ""
echo "=== EFS Create: COMPLETE ==="
echo "  EFS ID:      ${EFS_ID}"
echo "  DNS:         ${EFS_ID}.efs.${AWS_REGION}.amazonaws.com"
echo "  State file:  ${STATE_FILE}"
echo "  Cost:        ~\$0.30/GB-month while active"
echo "  Completed:   $(date)"
