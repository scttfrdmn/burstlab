#!/bin/bash
# =============================================================================
# scenario3/submit-chain.sh — Create ephemeral EFS and submit Slurm job chain
#
# EFS creation runs inline here on the head node (just AWS API calls — no
# burst node needed). Only the compute and destroy steps go to Slurm.
#
# Steps:
#   Step 0: Create EFS filesystem (inline, head node, ~60 seconds)
#   Job 1:  Run workload on ephemeral EFS (burst node, --partition=aws)
#   Job 2:  Destroy EFS filesystem (burst node, dependency afterok:Job1)
#
# Supports three granularity modes:
#   per-job      (default) — each submission creates its own EFS volume
#   per-array    — one EFS volume shared by all tasks in an array
#   per-campaign — named EFS volume shared across multiple job submissions
#
# SA talking point: "EFS is created right here on the head node — it's just
# an API call, we don't need a burst node for that. The mount target goes into
# the cloud burst subnet, exactly like it would in a real hybrid environment.
# Once the EFS is available (~60 seconds), we submit two jobs: one to run the
# workload on the burst node, one to destroy the EFS when it's done."
#
# Usage:
#   # Required environment variables from terraform output:
#   BURST_SUBNET_ID=$(cd terraform/workloads/scenario3-ephemeral-efs && terraform output -raw burst_subnet_id)
#   EFS_SG_ID=$(cd terraform/workloads/scenario3-ephemeral-efs && terraform output -raw efs_sg_id)
#
#   bash /opt/slurm/etc/workloads/jobs/scenario3/submit-chain.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
GRANULARITY="${GRANULARITY:-per-job}"
CAMPAIGN_NAME="${CAMPAIGN_NAME:-default}"
ARRAY_TASKS="${ARRAY_TASKS:-}"
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

# BURST_SUBNET_ID: the cloud-side subnet where burst nodes run and where the
# ephemeral EFS mount target should be created. In a real hybrid setup this
# would be a subnet in your cloud VPC — NOT on the on-prem network.
: "${BURST_SUBNET_ID:?BURST_SUBNET_ID must be set (from terraform output -raw burst_subnet_id)}"
: "${EFS_SG_ID:?EFS_SG_ID must be set (from terraform output -raw efs_sg_id)}"
: "${AWS_REGION:?AWS_REGION must be set}"

export GRANULARITY CAMPAIGN_NAME AWS_REGION BURST_SUBNET_ID EFS_SG_ID

EXPORT_VARS="ALL,GRANULARITY=${GRANULARITY},CAMPAIGN_NAME=${CAMPAIGN_NAME}"
EXPORT_VARS="${EXPORT_VARS},BURST_SUBNET_ID=${BURST_SUBNET_ID}"
EXPORT_VARS="${EXPORT_VARS},EFS_SG_ID=${EFS_SG_ID}"
EXPORT_VARS="${EXPORT_VARS},AWS_REGION=${AWS_REGION}"

# Ensure log directory exists before jobs try to write to it
mkdir -p /home/alice/logs

echo "=== Submitting ephemeral EFS job chain ==="
echo "  Granularity:  ${GRANULARITY}"
echo "  Campaign:     ${CAMPAIGN_NAME}"
echo "  Burst subnet: ${BURST_SUBNET_ID}  (cloud-side, NOT on-prem)"
echo "  EFS SG:       ${EFS_SG_ID}"
echo "  Region:       ${AWS_REGION}"
echo ""

# -----------------------------------------------------------------------------
# Step 0: Create EFS filesystem (runs inline on head node — no burst cost)
# -----------------------------------------------------------------------------
echo "Step 0: Creating EFS filesystem (running on head node)..."
source "${SCRIPT_DIR}/job1-create-efs.sh"

# Read the state file that job1 wrote so we can show the EFS ID and pass its
# exact path to Slurm jobs (avoids key mismatch between inline create and batch job IDs).
source /opt/slurm/etc/workloads/lib/efs-lifecycle.sh
EFS_STATE_FILE=$(resolve_state_file "${GRANULARITY}" "${CAMPAIGN_NAME}")
# shellcheck source=/dev/null
source "${EFS_STATE_FILE}"
echo ""
echo "  EFS ready: ${EFS_ID} (${EFS_DNS})"
echo ""

# Pass the state file path explicitly so batch jobs don't need to re-derive it
EXPORT_VARS="${EXPORT_VARS},EFS_STATE_FILE=${EFS_STATE_FILE}"

# -----------------------------------------------------------------------------
# Job 1: Run workload on ephemeral EFS (burst node)
# -----------------------------------------------------------------------------
if [ "$GRANULARITY" = "per-array" ] && [ -n "$ARRAY_TASKS" ]; then
  JOB1=$(sbatch --parsable \
    --job-name=efs-workload \
    --partition="${PARTITION}" \
    --array="${ARRAY_TASKS}" \
    --nodes=1 --ntasks=4 \
    --time=01:00:00 \
    --export="${EXPORT_VARS}" \
    "${SCRIPT_DIR}/job2-run-workload.sh")
else
  JOB1=$(sbatch --parsable \
    --job-name=efs-workload \
    --partition="${PARTITION}" \
    --nodes=1 --ntasks=4 \
    --time=01:00:00 \
    --export="${EXPORT_VARS}" \
    "${SCRIPT_DIR}/job2-run-workload.sh")
fi
echo "Job 1 (run workload): ${JOB1}"

# -----------------------------------------------------------------------------
# Job 2: Destroy EFS filesystem (afterok: workload)
# For per-campaign: skip auto-destroy.
# -----------------------------------------------------------------------------
if [ "$GRANULARITY" = "per-campaign" ]; then
  echo ""
  echo "Granularity=per-campaign: Job 2 (destroy) NOT submitted automatically."
  echo "The EFS volume persists until you end the campaign:"
  echo "  CAMPAIGN_NAME=${CAMPAIGN_NAME} AWS_REGION=${AWS_REGION} \\"
  echo "    bash ${SCRIPT_DIR}/job3-destroy-efs.sh"
  echo "Or submit it manually:"
  echo "  sbatch --dependency=afterok:${JOB1} --export='${EXPORT_VARS}' \\"
  echo "    ${SCRIPT_DIR}/job3-destroy-efs.sh"
else
  # Destroy job: just AWS API calls — runs on head node (no burst EC2 needed)
  JOB2=$(sbatch --parsable \
    --job-name=efs-destroy \
    --partition=local \
    --nodes=1 --ntasks=1 \
    --time=00:10:00 \
    --dependency=afterok:"${JOB1}" \
    --export="${EXPORT_VARS}" \
    "${SCRIPT_DIR}/job3-destroy-efs.sh")
  echo "Job 2 (destroy EFS): ${JOB2}"
fi

echo ""
echo "=== Chain submitted. Monitor with: ==="
echo "  watch -n 5 'squeue && echo && aws efs describe-file-systems \\"
echo "    --query \"FileSystems[].[FileSystemId,LifeCycleState]\" --output table'"
