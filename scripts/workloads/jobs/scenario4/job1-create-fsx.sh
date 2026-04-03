#!/bin/bash
# =============================================================================
# scenario4/job1-create-fsx.sh — Create ephemeral FSx Lustre filesystem
#
# Submitted by submit-chain.sh. Creates an FSx Lustre filesystem (SCRATCH_2)
# linked to the S3 data bucket, then writes the filesystem ID and DNS name
# to a state file on permanent cluster EFS so Job 2 can find it.
#
# SCRATCH_2 deployment type:
#   - $0.14/GB-month (1,200 GB minimum = ~$0.23/hr while active)
#   - Highest throughput, no replication, ephemeral
#   - AutoImportPolicy=NEW_CHANGED: S3 objects visible without manual HSM recall
#   - Lazy hydration: data streams from S3 on first read
#
# SA talking point: "Job 1 calls the FSx API to create a Lustre filesystem
# linked to S3. Takes 5-10 minutes to provision. While it's provisioning,
# no data is copied — the filesystem just knows where its data repository is.
# The FSx ID is written to the cluster's permanent EFS as the handoff to Job 2."
# =============================================================================

#SBATCH --job-name=fsx-create
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:20:00
#SBATCH --output=/u/home/alice/logs/fsx-create-%j.out
#SBATCH --error=/u/home/alice/logs/fsx-create-%j.err

set -euo pipefail
mkdir -p /u/home/alice/logs

source /opt/slurm/etc/workloads/lib/fsx-lifecycle.sh

echo "=== FSx Create: started on $(hostname): $(date) ==="
echo "  Job ID:         ${SLURM_JOB_ID}"
echo "  Granularity:    ${GRANULARITY}"
echo "  Subnet:         ${CLOUD_SUBNET_A_ID}"
echo "  SG:             ${FSX_SG_ID}"
echo "  S3 bucket:      ${S3_DATA_BUCKET}"
echo "  Storage:        ${FSX_STORAGE_GB:-1200} GB"
echo "  Region:         ${AWS_REGION}"

# Determine state file location for this granularity mode
STATE_FILE=$(resolve_fsx_state_file "${GRANULARITY}" "${CAMPAIGN_NAME:-default}")
echo "  State file:     ${STATE_FILE}"

# Check idempotency — don't create a second FSx if state file already exists
if [ -f "${STATE_FILE}" ]; then
  # shellcheck source=/dev/null
  source "${STATE_FILE}"
  echo "State file exists (FSX_ID=${FSX_ID:-unknown}) — checking if still valid..."
  EXISTING_STATE=$(aws fsx describe-file-systems \
    --file-system-ids "${FSX_ID:-none}" \
    --region "${AWS_REGION}" \
    --query 'FileSystems[0].Lifecycle' \
    --output text 2>/dev/null || echo "not-found")

  if [ "$EXISTING_STATE" = "AVAILABLE" ]; then
    echo "Existing FSx ${FSX_ID} is still AVAILABLE — skipping creation."
    echo "To force recreate: rm ${STATE_FILE}"
    exit 0
  else
    echo "Existing FSx not found or not available (${EXISTING_STATE}) — creating new one."
    rm -f "${STATE_FILE}"
  fi
fi

# Stage input data into S3 before creating FSx (so it's ready for lazy hydration)
echo ""
echo "Staging input data to s3://${S3_DATA_BUCKET}/input/..."
S3_PREFIX="jobs/${SLURM_JOB_ID}"

if [ -d "/opt/slurm/etc/workloads/data" ]; then
  aws s3 sync /opt/slurm/etc/workloads/data/ \
    "s3://${S3_DATA_BUCKET}/${S3_PREFIX}/input/" \
    --region "${AWS_REGION}" \
    --quiet || true
fi

# Create synthetic input if no data was available
OBJECT_COUNT=$(aws s3 ls "s3://${S3_DATA_BUCKET}/${S3_PREFIX}/input/" \
  --region "${AWS_REGION}" 2>/dev/null | wc -l || echo 0)

if [ "${OBJECT_COUNT}" -eq 0 ]; then
  echo "Generating synthetic workload data in S3..."
  for i in $(seq 1 5); do
    dd if=/dev/urandom bs=1M count=20 2>/dev/null | base64 | \
      aws s3 cp - "s3://${S3_DATA_BUCKET}/${S3_PREFIX}/input/data-${i}.dat" \
        --region "${AWS_REGION}" --quiet
  done
fi

echo "  Input data ready at s3://${S3_DATA_BUCKET}/${S3_PREFIX}/input/"

# Create the FSx Lustre filesystem linked to S3
echo ""
echo "Creating FSx Lustre filesystem..."
FSX_ID=$(fsx_create \
  "${SLURM_JOB_ID}" \
  "${S3_DATA_BUCKET}" \
  "${S3_PREFIX}" \
  "${CLOUD_SUBNET_A_ID}" \
  "${FSX_SG_ID}" \
  "${FSX_STORAGE_GB:-1200}")
echo "  Created: ${FSX_ID}"

# Wait for filesystem to be available (5-10 minutes)
fsx_wait_available "${FSX_ID}"

# Get DNS name for mounting
FSX_DNS=$(fsx_get_dns "${FSX_ID}")
echo "  DNS: ${FSX_DNS}"

# Get the mount name (needed for Lustre mount)
FSX_MOUNT_NAME=$(aws fsx describe-file-systems \
  --file-system-ids "${FSX_ID}" \
  --region "${AWS_REGION}" \
  --query 'FileSystems[0].LustreConfiguration.MountName' \
  --output text)
echo "  Mount name: ${FSX_MOUNT_NAME}"

# Write state file to permanent cluster EFS — Job 2 reads this
cat > "${STATE_FILE}" << EOF
# BurstLab ephemeral FSx Lustre state
# Created by Job ${SLURM_JOB_ID} at $(date -u +%Y-%m-%dT%H:%M:%SZ)
FSX_ID=${FSX_ID}
FSX_DNS=${FSX_DNS}
FSX_MOUNT_NAME=${FSX_MOUNT_NAME}
S3_DATA_BUCKET=${S3_DATA_BUCKET}
S3_PREFIX=${S3_PREFIX}
CREATED_BY_JOB=${SLURM_JOB_ID}
GRANULARITY=${GRANULARITY}
CAMPAIGN_NAME=${CAMPAIGN_NAME:-default}
EOF

echo ""
echo "=== FSx Create: COMPLETE ==="
echo "  FSx ID:         ${FSX_ID}"
echo "  DNS:            ${FSX_DNS}"
echo "  Mount name:     ${FSX_MOUNT_NAME}"
echo "  State file:     ${STATE_FILE}"
echo "  Storage:        ${FSX_STORAGE_GB:-1200} GB SCRATCH_2"
echo "  Cost:           ~\$0.14/GB-month while active"
echo "  Completed:      $(date)"
