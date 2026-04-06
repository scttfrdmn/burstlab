#!/bin/bash
# =============================================================================
# scenario4/submit-chain-restore.sh — Restore: create FSx from existing S3 data
#
# This is the second half of the S3-as-permanent-store proof. After a write chain
# has flushed results to S3 and destroyed the FSx filesystem, this script creates
# a NEW FSx filesystem linked to the SAME S3 prefix — proving that the data is
# durable and can be re-hydrated into fresh Lustre storage.
#
# Steps:
#   Step 0: Create FSx Lustre linked to the previous S3 prefix (inline, ~5-10 min)
#   Job 1:  Verify data hydration — check files exist, read them, verify checksums
#   Job 2:  Destroy FSx (afterok:Job1)
#
# Usage:
#   bash submit-chain-restore.sh <RUN_ID>
#   bash submit-chain-restore.sh --run <RUN_ID>
#   bash submit-chain-restore.sh \
#     --s3-data-bucket <BUCKET> --s3-prefix <PREFIX>
#
# The user-facing wrapper is: fsx-restore <RUN_ID>
#
# SA talking point: "We destroyed the FSx filesystem 10 minutes ago. The data is
# in S3 at $0.023/GB-month. Now we're creating a brand new Lustre filesystem
# pointing at the same S3 prefix. Watch — the files appear immediately as stubs.
# When the verification job reads them, Lustre hydrates from S3 on demand. This
# proves S3 is the ground truth and FSx is just a cache."
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HISTORY_DIR="${HOME}/.fsx-history"

# Defaults
RUN_ID=""
S3_DATA_BUCKET="${S3_DATA_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-}"
PARTITION="${PARTITION:-aws}"
FSX_STORAGE_GB="${FSX_STORAGE_GB:-1200}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --run)            RUN_ID="$2";         shift 2 ;;
    --s3-data-bucket) S3_DATA_BUCKET="$2"; shift 2 ;;
    --s3-prefix)      S3_PREFIX="$2";      shift 2 ;;
    --partition)      PARTITION="$2";      shift 2 ;;
    --fsx-storage-gb) FSX_STORAGE_GB="$2"; shift 2 ;;
    -*)               echo "Unknown option: $1"; exit 1 ;;
    *)                RUN_ID="$1";         shift   ;;  # positional arg = run ID
  esac
done

# Load from run record if a run ID was given
if [ -n "${RUN_ID}" ]; then
  RUN_FILE="${HISTORY_DIR}/${RUN_ID}.run"
  if [ ! -f "${RUN_FILE}" ]; then
    echo "ERROR: Run '${RUN_ID}' not found." >&2
    echo "Use 'fsx-list' to see available runs." >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${RUN_FILE}"
  echo "Loaded run record: ${RUN_FILE}"
fi

# Source sysconfig for any vars not yet set
if [ -f /etc/sysconfig/burstlab-workloads ]; then
  # shellcheck source=/dev/null
  source /etc/sysconfig/burstlab-workloads
fi

: "${S3_DATA_BUCKET:?S3_DATA_BUCKET must be set (from campaign record or env)}"
: "${S3_PREFIX:?S3_PREFIX must be set (from campaign record or env)}"
: "${BURST_SUBNET_ID:?BURST_SUBNET_ID must be set}"
: "${FSX_SG_ID:?FSX_SG_ID must be set}"
: "${AWS_REGION:?AWS_REGION must be set}"

export AWS_REGION BURST_SUBNET_ID FSX_SG_ID S3_DATA_BUCKET S3_PREFIX FSX_STORAGE_GB

RESTORE_REF="restore-$(date +%s)"
GRANULARITY="per-job"

mkdir -p /home/alice/logs

CAMPAIGN_NAME="${LABEL:-restore}"

echo "=== Submitting FSx restore chain ==="
echo "  Run ID:         ${RUN_ID:-manual}"
echo "  S3 data:        s3://${S3_DATA_BUCKET}/${S3_PREFIX}/"
echo "  Burst subnet:   ${BURST_SUBNET_ID}"
echo "  FSx SG:         ${FSX_SG_ID}"
echo "  FSx storage:    ${FSX_STORAGE_GB} GB"
echo "  Region:         ${AWS_REGION}"
echo ""

# Verify S3 data exists before creating FSx
echo "Checking S3 data exists..."
OUTPUT_COUNT=$(aws s3 ls "s3://${S3_DATA_BUCKET}/${S3_PREFIX}/output/" \
  --recursive --region "${AWS_REGION}" 2>/dev/null | wc -l || echo 0)

if [ "${OUTPUT_COUNT}" -eq 0 ]; then
  echo "ERROR: No output data found at s3://${S3_DATA_BUCKET}/${S3_PREFIX}/output/" >&2
  echo "The write chain may not have completed, or the data bucket was destroyed." >&2
  exit 1
fi
echo "  Found ${OUTPUT_COUNT} objects in S3 output — proceeding."
echo ""

# -----------------------------------------------------------------------------
# Step 0: Create FSx Lustre linked to the SAME S3 prefix (runs inline on head node)
# -----------------------------------------------------------------------------
echo "Step 0: Creating FSx Lustre from existing S3 data (running on head node)..."
echo "  NOTE: FSx provisioning takes 5-10 minutes."
echo "  The previous chain's data in S3 will be visible immediately as stubs."
echo ""

source /opt/slurm/etc/workloads/lib/fsx-lifecycle.sh

FSX_ID=$(fsx_create \
  "${RESTORE_REF}" \
  "${S3_DATA_BUCKET}" \
  "${S3_PREFIX}" \
  "${BURST_SUBNET_ID}" \
  "${FSX_SG_ID}" \
  "${FSX_STORAGE_GB}")
echo "  Created: ${FSX_ID}"

fsx_wait_available "${FSX_ID}"

FSX_DNS=$(fsx_get_dns "${FSX_ID}")
FSX_MOUNT_NAME=$(aws fsx describe-file-systems \
  --file-system-ids "${FSX_ID}" \
  --region "${AWS_REGION}" \
  --query 'FileSystems[0].LustreConfiguration.MountName' \
  --output text)

# Write state file for the verify and destroy jobs
FSX_STATE_DIR="${HOME}/.fsx-state"
mkdir -p "${FSX_STATE_DIR}"
STATE_FILE="${FSX_STATE_DIR}/job-${RESTORE_REF}.env"
cat > "${STATE_FILE}" << EOF
# BurstLab FSx restore state
# Created at $(date -u +%Y-%m-%dT%H:%M:%SZ)
FSX_ID=${FSX_ID}
FSX_DNS=${FSX_DNS}
FSX_MOUNT_NAME=${FSX_MOUNT_NAME}
S3_DATA_BUCKET=${S3_DATA_BUCKET}
S3_PREFIX=${S3_PREFIX}
AWS_REGION=${AWS_REGION}
CREATED_BY_JOB=${RESTORE_REF}
GRANULARITY=${GRANULARITY}
CAMPAIGN_NAME=${CAMPAIGN_NAME:-restore}
EOF

echo ""
echo "  FSx ready: ${FSX_ID} (${FSX_DNS})"
echo "  State file: ${STATE_FILE}"
echo ""

EXPORT_VARS="ALL,FSX_STATE_FILE=${STATE_FILE}"
EXPORT_VARS="${EXPORT_VARS},GRANULARITY=${GRANULARITY},CAMPAIGN_NAME=${CAMPAIGN_NAME:-restore}"
EXPORT_VARS="${EXPORT_VARS},BURST_SUBNET_ID=${BURST_SUBNET_ID},FSX_SG_ID=${FSX_SG_ID}"
EXPORT_VARS="${EXPORT_VARS},S3_DATA_BUCKET=${S3_DATA_BUCKET},AWS_REGION=${AWS_REGION}"

# -----------------------------------------------------------------------------
# Job 1: Verify data hydration (burst node)
# -----------------------------------------------------------------------------
JOB1=$(sbatch --parsable \
  --job-name=fsx-verify-restore \
  --partition="${PARTITION}" \
  --nodes=1 --ntasks=1 \
  --time=00:30:00 \
  --export="${EXPORT_VARS}" \
  "${SCRIPT_DIR}/job4-verify-restore.sh")
echo "Job 1 (verify restore): ${JOB1}"

# -----------------------------------------------------------------------------
# Job 2: Destroy FSx (afterok: verify — no flush needed, data already in S3)
# -----------------------------------------------------------------------------
JOB2=$(sbatch --parsable \
  --job-name=fsx-destroy \
  --partition=local \
  --nodes=1 --ntasks=1 \
  --time=00:10:00 \
  --dependency=afterok:"${JOB1}" \
  --export="${EXPORT_VARS}" \
  "${SCRIPT_DIR}/job3-destroy-fsx.sh")
echo "Job 2 (destroy FSx):    ${JOB2}"

echo ""
echo "=== Restore chain submitted. Monitor with: ==="
echo "  watch -n 10 squeue"
echo ""
echo "After Job 1 completes, check the verification output:"
echo "  cat /home/alice/logs/fsx-verify-restore-${JOB1}.out"
