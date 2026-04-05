#!/bin/bash
# =============================================================================
# scenario4/submit-chain.sh — Create ephemeral FSx Lustre and submit job chain
#
# FSx creation runs inline here on the head node (just AWS API calls — no
# burst node needed for provisioning). Only the compute and destroy steps
# go to Slurm.
#
# Steps:
#   Step 0: Create FSx Lustre filesystem (inline, head node, ~5-10 minutes)
#   Job 1:  Run workload on ephemeral FSx (burst node, --partition=aws)
#   Job 2:  Flush results to S3 and destroy FSx (burst node, afterok:Job1)
#
# SA talking point: "FSx takes 5-10 minutes to provision — but that's AWS API
# time, not compute time. The head node submits the create request and waits
# here. No burst nodes are running during provisioning. Once FSx is available,
# two jobs go into the queue. Job 1 runs the workload with lazy hydration from
# S3. Job 2 flushes results back to S3 and destroys the filesystem."
#
# Usage:
#   BURST_SUBNET_ID=$(cd terraform/workloads/scenario4-ephemeral-fsx && terraform output -raw burst_subnet_id)
#   FSX_SG_ID=$(cd terraform/workloads/scenario4-ephemeral-fsx && terraform output -raw fsx_sg_id)
#   S3_DATA_BUCKET=$(cd terraform/workloads/scenario4-ephemeral-fsx && terraform output -raw s3_data_bucket)
#
#   bash /opt/slurm/etc/workloads/jobs/scenario4/submit-chain.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
GRANULARITY="${GRANULARITY:-per-job}"
CAMPAIGN_NAME="${CAMPAIGN_NAME:-default}"
ARRAY_TASKS="${ARRAY_TASKS:-}"
PARTITION="${PARTITION:-aws}"
FSX_STORAGE_GB="${FSX_STORAGE_GB:-1200}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --granularity)    GRANULARITY="$2";    shift 2 ;;
    --campaign-name)  CAMPAIGN_NAME="$2";  shift 2 ;;
    --array-tasks)    ARRAY_TASKS="$2";    shift 2 ;;
    --partition)      PARTITION="$2";      shift 2 ;;
    --fsx-storage-gb) FSX_STORAGE_GB="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

: "${BURST_SUBNET_ID:?BURST_SUBNET_ID must be set (from terraform output -raw burst_subnet_id)}"
: "${FSX_SG_ID:?FSX_SG_ID must be set (from terraform output -raw fsx_sg_id)}"
: "${S3_DATA_BUCKET:?S3_DATA_BUCKET must be set (from terraform output -raw s3_data_bucket)}"
: "${AWS_REGION:?AWS_REGION must be set}"

export GRANULARITY CAMPAIGN_NAME AWS_REGION BURST_SUBNET_ID FSX_SG_ID S3_DATA_BUCKET FSX_STORAGE_GB

EXPORT_VARS="ALL,GRANULARITY=${GRANULARITY},CAMPAIGN_NAME=${CAMPAIGN_NAME}"
EXPORT_VARS="${EXPORT_VARS},BURST_SUBNET_ID=${BURST_SUBNET_ID}"
EXPORT_VARS="${EXPORT_VARS},FSX_SG_ID=${FSX_SG_ID}"
EXPORT_VARS="${EXPORT_VARS},S3_DATA_BUCKET=${S3_DATA_BUCKET}"
EXPORT_VARS="${EXPORT_VARS},FSX_STORAGE_GB=${FSX_STORAGE_GB}"
EXPORT_VARS="${EXPORT_VARS},AWS_REGION=${AWS_REGION}"

mkdir -p /home/alice/logs

echo "=== Submitting ephemeral FSx Lustre job chain ==="
echo "  Granularity:    ${GRANULARITY}"
echo "  Campaign:       ${CAMPAIGN_NAME}"
echo "  Burst subnet:   ${BURST_SUBNET_ID}  (cloud-side, NOT on-prem)"
echo "  FSx SG:         ${FSX_SG_ID}"
echo "  S3 data bucket: ${S3_DATA_BUCKET}"
echo "  FSx storage:    ${FSX_STORAGE_GB} GB"
echo "  Region:         ${AWS_REGION}"
echo ""
echo "  NOTE: FSx provisioning takes 5-10 minutes (no burst nodes running during this time)."
echo ""

# -----------------------------------------------------------------------------
# Step 0: Create FSx Lustre filesystem (runs inline on head node)
# -----------------------------------------------------------------------------
echo "Step 0: Creating FSx Lustre filesystem (running on head node)..."
source "${SCRIPT_DIR}/job1-create-fsx.sh"

# Read the state file that job1 wrote; pass the path explicitly to avoid
# Slurm job ID key mismatch with the inline (head node) create.
source /opt/slurm/etc/workloads/lib/fsx-lifecycle.sh
FSX_STATE_FILE=$(resolve_fsx_state_file "${GRANULARITY}" "${CAMPAIGN_NAME}")
# shellcheck source=/dev/null
source "${FSX_STATE_FILE}"
echo ""
echo "  FSx ready: ${FSX_ID} (${FSX_DNS})"
echo ""

EXPORT_VARS="${EXPORT_VARS},FSX_STATE_FILE=${FSX_STATE_FILE}"

# -----------------------------------------------------------------------------
# Job 1: Run workload on ephemeral FSx Lustre (burst node)
# -----------------------------------------------------------------------------
if [ "$GRANULARITY" = "per-array" ] && [ -n "$ARRAY_TASKS" ]; then
  JOB1=$(sbatch --parsable \
    --job-name=fsx-workload \
    --partition="${PARTITION}" \
    --array="${ARRAY_TASKS}" \
    --nodes=1 --ntasks=4 \
    --time=01:00:00 \
    --export="${EXPORT_VARS}" \
    "${SCRIPT_DIR}/job2-run-workload.sh")
else
  JOB1=$(sbatch --parsable \
    --job-name=fsx-workload \
    --partition="${PARTITION}" \
    --nodes=1 --ntasks=4 \
    --time=01:00:00 \
    --export="${EXPORT_VARS}" \
    "${SCRIPT_DIR}/job2-run-workload.sh")
fi
echo "Job 1 (run workload): ${JOB1}"

# -----------------------------------------------------------------------------
# Job 2: Flush results to S3 and destroy FSx (afterok: workload)
# For per-campaign: skip auto-destroy.
# -----------------------------------------------------------------------------
if [ "$GRANULARITY" = "per-campaign" ]; then
  echo ""
  echo "Granularity=per-campaign: Job 2 (destroy) NOT submitted automatically."
  echo "The FSx volume persists until you end the campaign:"
  echo "  CAMPAIGN_NAME=${CAMPAIGN_NAME} AWS_REGION=${AWS_REGION} S3_DATA_BUCKET=${S3_DATA_BUCKET} \\"
  echo "    bash ${SCRIPT_DIR}/job3-destroy-fsx.sh"
  echo "Or submit it manually:"
  echo "  sbatch --dependency=afterok:${JOB1} --export='${EXPORT_VARS}' \\"
  echo "    ${SCRIPT_DIR}/job3-destroy-fsx.sh"
else
  # Destroy job: just AWS API calls — runs on head node (no burst EC2 needed)
  JOB2=$(sbatch --parsable \
    --job-name=fsx-destroy \
    --partition=local \
    --nodes=1 --ntasks=1 \
    --time=00:20:00 \
    --dependency=afterok:"${JOB1}" \
    --export="${EXPORT_VARS}" \
    "${SCRIPT_DIR}/job3-destroy-fsx.sh")
  echo "Job 2 (flush + destroy FSx): ${JOB2}"
fi

echo ""
echo "=== Chain submitted. Monitor with: ==="
echo "  watch -n 10 'squeue && echo && aws fsx describe-file-systems \\"
echo "    --query \"FileSystems[].[FileSystemId,Lifecycle,StorageCapacity]\" --output table'"
