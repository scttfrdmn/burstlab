#!/bin/bash
# =============================================================================
# scenario3/submit-chain.sh — Submit the ephemeral EFS three-job dependency chain
#
# Submits three Slurm jobs with --dependency=afterok:
#   Job 1: Creates an EFS filesystem, writes its ID to a state file on EFS
#   Job 2: Mounts the ephemeral EFS, runs the workload, unmounts
#   Job 3: Destroys the EFS filesystem (mount targets + filesystem)
#
# Supports three granularity modes:
#   per-job      (default) — each submission creates its own EFS volume
#   per-array    — one EFS volume shared by all tasks in an array
#   per-campaign — named EFS volume shared across multiple job submissions
#
# SA talking point: "Watch the three jobs in squeue. Job 1 creates the EFS
# in about 60 seconds. Job 2 runs on the ephemeral storage. Job 3 destroys
# it — the EFS filesystem disappears from the AWS console. The cluster's
# permanent EFS (where /u and /opt/slurm live) is untouched."
#
# Usage:
#   # Required environment variables from terraform output:
#   CLOUD_SUBNET_A_ID=$(cd terraform/workloads/scenario3-ephemeral-efs && terraform output -raw cloud_subnet_a_id)
#   EFS_SG_ID=$(cd terraform/workloads/scenario3-ephemeral-efs && terraform output -raw efs_sg_id)
#
#   # Submit with default per-job granularity:
#   CLOUD_SUBNET_A_ID=$CLOUD_SUBNET_A_ID EFS_SG_ID=$EFS_SG_ID AWS_REGION=us-west-2 \
#     bash /opt/slurm/etc/workloads/jobs/scenario3/submit-chain.sh
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

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --granularity)    GRANULARITY="$2";    shift 2 ;;
    --campaign-name)  CAMPAIGN_NAME="$2";  shift 2 ;;
    --array-tasks)    ARRAY_TASKS="$2";    shift 2 ;;
    --partition)      PARTITION="$2";      shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# Validate required environment variables
: "${CLOUD_SUBNET_A_ID:?CLOUD_SUBNET_A_ID must be set (from terraform output -raw cloud_subnet_a_id)}"
: "${EFS_SG_ID:?EFS_SG_ID must be set (from terraform output -raw efs_sg_id)}"
: "${AWS_REGION:?AWS_REGION must be set}"

EXPORT_VARS="ALL,GRANULARITY=${GRANULARITY},CAMPAIGN_NAME=${CAMPAIGN_NAME}"
EXPORT_VARS="${EXPORT_VARS},CLOUD_SUBNET_A_ID=${CLOUD_SUBNET_A_ID}"
EXPORT_VARS="${EXPORT_VARS},EFS_SG_ID=${EFS_SG_ID}"
EXPORT_VARS="${EXPORT_VARS},AWS_REGION=${AWS_REGION}"

echo "=== Submitting ephemeral EFS job chain ==="
echo "  Granularity:       ${GRANULARITY}"
echo "  Campaign:          ${CAMPAIGN_NAME}"
echo "  Subnet:            ${CLOUD_SUBNET_A_ID}"
echo "  EFS SG:            ${EFS_SG_ID}"
echo "  Region:            ${AWS_REGION}"
echo ""

# -----------------------------------------------------------------------------
# Job 1: Create EFS filesystem
# Runs on the aws partition (burst node). Fast job — just AWS API calls.
# -----------------------------------------------------------------------------
JOB1=$(sbatch --parsable \
  --job-name=efs-create \
  --partition="${PARTITION}" \
  --nodes=1 --ntasks=1 \
  --time=00:10:00 \
  --export="${EXPORT_VARS}" \
  "${SCRIPT_DIR}/job1-create-efs.sh")
echo "Job 1 (create EFS): ${JOB1}"

# -----------------------------------------------------------------------------
# Job 2: Run workload on ephemeral EFS
# Waits for Job 1. For per-array: submit as array job.
# -----------------------------------------------------------------------------
if [ "$GRANULARITY" = "per-array" ] && [ -n "$ARRAY_TASKS" ]; then
  JOB2=$(sbatch --parsable \
    --job-name=efs-workload \
    --partition="${PARTITION}" \
    --array="${ARRAY_TASKS}" \
    --nodes=1 --ntasks=4 \
    --time=01:00:00 \
    --dependency=afterok:"${JOB1}" \
    --export="${EXPORT_VARS}" \
    "${SCRIPT_DIR}/job2-run-workload.sh")
else
  JOB2=$(sbatch --parsable \
    --job-name=efs-workload \
    --partition="${PARTITION}" \
    --nodes=1 --ntasks=4 \
    --time=01:00:00 \
    --dependency=afterok:"${JOB1}" \
    --export="${EXPORT_VARS}" \
    "${SCRIPT_DIR}/job2-run-workload.sh")
fi
echo "Job 2 (run workload): ${JOB2}"

# -----------------------------------------------------------------------------
# Job 3: Destroy EFS filesystem
# Waits for all tasks in Job 2 (afterok handles arrays correctly).
# For per-campaign: skip auto-destroy (campaign ends manually).
# -----------------------------------------------------------------------------
if [ "$GRANULARITY" = "per-campaign" ]; then
  echo ""
  echo "Granularity=per-campaign: Job 3 (destroy) NOT submitted automatically."
  echo "The EFS volume persists until you end the campaign:"
  echo "  CAMPAIGN_NAME=${CAMPAIGN_NAME} AWS_REGION=${AWS_REGION} \\"
  echo "    bash ${SCRIPT_DIR}/job3-destroy-efs.sh"
  echo "Or submit it manually:"
  echo "  sbatch --dependency=afterok:${JOB2} --export='${EXPORT_VARS}' \\"
  echo "    ${SCRIPT_DIR}/job3-destroy-efs.sh"
else
  JOB3=$(sbatch --parsable \
    --job-name=efs-destroy \
    --partition="${PARTITION}" \
    --nodes=1 --ntasks=1 \
    --time=00:10:00 \
    --dependency=afterok:"${JOB2}" \
    --export="${EXPORT_VARS}" \
    "${SCRIPT_DIR}/job3-destroy-efs.sh")
  echo "Job 3 (destroy EFS): ${JOB3}"
fi

echo ""
echo "=== Chain submitted. Monitor with: ==="
echo "  watch -n 5 'squeue && echo && aws efs describe-file-systems \\"
echo "    --query \"FileSystems[].[FileSystemId,LifeCycleState]\" --output table'"
