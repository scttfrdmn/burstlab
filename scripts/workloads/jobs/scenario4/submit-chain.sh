#!/bin/bash
# =============================================================================
# scenario4/submit-chain.sh — Submit the ephemeral FSx Lustre three-job chain
#
# Submits three Slurm jobs with --dependency=afterok:
#   Job 1: Creates an FSx Lustre filesystem linked to S3, writes its ID to EFS
#   Job 2: Mounts FSx, runs the workload (data hydrates lazily from S3)
#   Job 3: Flushes results to S3, waits for export, destroys FSx filesystem
#
# Supports three granularity modes:
#   per-job      (default) — each submission creates its own FSx volume
#   per-array    — one FSx volume shared by all tasks in an array
#   per-campaign — named FSx volume shared across multiple job submissions
#
# SA talking point: "FSx Lustre is the HPC-grade parallel filesystem on AWS.
# Watch Job 1 — it takes 5-10 minutes to provision. Then Job 2 runs — files
# hydrate lazily from S3 as the application reads them. Job 3 flushes results
# back to S3 and destroys the filesystem. You only pay for FSx while it exists.
# Minimum charge is 1,200 GB (~$168/mo at $0.14/GB-month = ~$0.23/hr)."
#
# Usage:
#   # Required environment variables from terraform output:
#   CLOUD_SUBNET_A_ID=$(cd terraform/workloads/scenario4-ephemeral-fsx && terraform output -raw cloud_subnet_a_id)
#   FSX_SG_ID=$(cd terraform/workloads/scenario4-ephemeral-fsx && terraform output -raw fsx_sg_id)
#   S3_DATA_BUCKET=$(cd terraform/workloads/scenario4-ephemeral-fsx && terraform output -raw s3_data_bucket)
#
#   # Submit with default per-job granularity:
#   CLOUD_SUBNET_A_ID=$CLOUD_SUBNET_A_ID FSX_SG_ID=$FSX_SG_ID \
#     S3_DATA_BUCKET=$S3_DATA_BUCKET AWS_REGION=us-west-2 \
#     bash /opt/slurm/etc/workloads/jobs/scenario4/submit-chain.sh
#
#   # Per-campaign (persistent across submissions):
#   bash submit-chain.sh --granularity per-campaign --campaign-name protein-sweep
#
# Outputs the three job IDs and the submission summary.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
GRANULARITY="${GRANULARITY:-per-job}"
CAMPAIGN_NAME="${CAMPAIGN_NAME:-default}"
ARRAY_TASKS="${ARRAY_TASKS:-}"   # e.g. "0-7" for per-array mode
PARTITION="${PARTITION:-aws}"
FSX_STORAGE_GB="${FSX_STORAGE_GB:-1200}"   # minimum is 1200 GB

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

# Validate required environment variables
: "${CLOUD_SUBNET_A_ID:?CLOUD_SUBNET_A_ID must be set (from terraform output -raw cloud_subnet_a_id)}"
: "${FSX_SG_ID:?FSX_SG_ID must be set (from terraform output -raw fsx_sg_id)}"
: "${S3_DATA_BUCKET:?S3_DATA_BUCKET must be set (from terraform output -raw s3_data_bucket)}"
: "${AWS_REGION:?AWS_REGION must be set}"

EXPORT_VARS="ALL,GRANULARITY=${GRANULARITY},CAMPAIGN_NAME=${CAMPAIGN_NAME}"
EXPORT_VARS="${EXPORT_VARS},CLOUD_SUBNET_A_ID=${CLOUD_SUBNET_A_ID}"
EXPORT_VARS="${EXPORT_VARS},FSX_SG_ID=${FSX_SG_ID}"
EXPORT_VARS="${EXPORT_VARS},S3_DATA_BUCKET=${S3_DATA_BUCKET}"
EXPORT_VARS="${EXPORT_VARS},FSX_STORAGE_GB=${FSX_STORAGE_GB}"
EXPORT_VARS="${EXPORT_VARS},AWS_REGION=${AWS_REGION}"

echo "=== Submitting ephemeral FSx Lustre job chain ==="
echo "  Granularity:       ${GRANULARITY}"
echo "  Campaign:          ${CAMPAIGN_NAME}"
echo "  Subnet:            ${CLOUD_SUBNET_A_ID}"
echo "  FSx SG:            ${FSX_SG_ID}"
echo "  S3 data bucket:    ${S3_DATA_BUCKET}"
echo "  FSx storage:       ${FSX_STORAGE_GB} GB"
echo "  Region:            ${AWS_REGION}"
echo ""
echo "  NOTE: Job 1 takes 5-10 minutes (FSx provisioning)."
echo "        Minimum FSx cost: ~\$0.23/hr while active (1200 GB minimum)."
echo ""

# -----------------------------------------------------------------------------
# Job 1: Create FSx Lustre filesystem
# Longer timeout — FSx provisioning takes 5-10 minutes.
# -----------------------------------------------------------------------------
JOB1=$(sbatch --parsable \
  --job-name=fsx-create \
  --partition="${PARTITION}" \
  --nodes=1 --ntasks=1 \
  --time=00:20:00 \
  --export="${EXPORT_VARS}" \
  "${SCRIPT_DIR}/job1-create-fsx.sh")
echo "Job 1 (create FSx): ${JOB1}"

# -----------------------------------------------------------------------------
# Job 2: Run workload on ephemeral FSx Lustre
# Waits for Job 1. For per-array: submit as array job.
# -----------------------------------------------------------------------------
if [ "$GRANULARITY" = "per-array" ] && [ -n "$ARRAY_TASKS" ]; then
  JOB2=$(sbatch --parsable \
    --job-name=fsx-workload \
    --partition="${PARTITION}" \
    --array="${ARRAY_TASKS}" \
    --nodes=1 --ntasks=4 \
    --time=01:00:00 \
    --dependency=afterok:"${JOB1}" \
    --export="${EXPORT_VARS}" \
    "${SCRIPT_DIR}/job2-run-workload.sh")
else
  JOB2=$(sbatch --parsable \
    --job-name=fsx-workload \
    --partition="${PARTITION}" \
    --nodes=1 --ntasks=4 \
    --time=01:00:00 \
    --dependency=afterok:"${JOB1}" \
    --export="${EXPORT_VARS}" \
    "${SCRIPT_DIR}/job2-run-workload.sh")
fi
echo "Job 2 (run workload): ${JOB2}"

# -----------------------------------------------------------------------------
# Job 3: Flush results to S3 and destroy FSx filesystem
# Waits for all tasks in Job 2. For per-campaign: skip auto-destroy.
# -----------------------------------------------------------------------------
if [ "$GRANULARITY" = "per-campaign" ]; then
  echo ""
  echo "Granularity=per-campaign: Job 3 (destroy) NOT submitted automatically."
  echo "The FSx volume persists until you end the campaign:"
  echo "  CAMPAIGN_NAME=${CAMPAIGN_NAME} AWS_REGION=${AWS_REGION} S3_DATA_BUCKET=${S3_DATA_BUCKET} \\"
  echo "    bash ${SCRIPT_DIR}/job3-destroy-fsx.sh"
  echo "Or submit it manually:"
  echo "  sbatch --dependency=afterok:${JOB2} --export='${EXPORT_VARS}' \\"
  echo "    ${SCRIPT_DIR}/job3-destroy-fsx.sh"
else
  JOB3=$(sbatch --parsable \
    --job-name=fsx-destroy \
    --partition="${PARTITION}" \
    --nodes=1 --ntasks=1 \
    --time=00:20:00 \
    --dependency=afterok:"${JOB2}" \
    --export="${EXPORT_VARS}" \
    "${SCRIPT_DIR}/job3-destroy-fsx.sh")
  echo "Job 3 (flush + destroy FSx): ${JOB3}"
fi

echo ""
echo "=== Chain submitted. Monitor with: ==="
echo "  watch -n 10 'squeue && echo && aws fsx describe-file-systems \\"
echo "    --query \"FileSystems[].[FileSystemId,Lifecycle,StorageCapacity]\" --output table'"
