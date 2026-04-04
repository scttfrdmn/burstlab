#!/bin/bash
# =============================================================================
# lib/efs-lifecycle.sh — Shared EFS lifecycle functions for Scenario 3 jobs
#
# Source this file in job scripts:
#   source /opt/slurm/etc/workloads/lib/efs-lifecycle.sh
#
# Provides:
#   efs_create         — Create an EFS filesystem; returns filesystem ID
#   efs_add_mount_target — Add a mount target in the given subnet
#   efs_wait_available — Poll until filesystem is in 'available' state
#   efs_wait_mount_target — Poll until mount target is in 'available' state
#   efs_destroy        — Delete mount targets then the filesystem
#   resolve_state_file — Return state file path for given granularity mode
#
# Required environment variables (set by submit-chain.sh):
#   AWS_REGION          — AWS region
#   CLOUD_SUBNET_A_ID   — Subnet for the EFS mount target
#   EFS_SG_ID           — Security group allowing NFS (2049) from VPC CIDR
#   GRANULARITY         — per-job | per-array | per-campaign
#   CAMPAIGN_NAME       — only required when GRANULARITY=per-campaign
# =============================================================================

# Strict mode — any unset variable or command failure exits the job
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-west-2}"
EFS_STATE_DIR="${EFS_STATE_DIR:-/u/home/alice/.efs-state}"

# -----------------------------------------------------------------------------
# efs_create <job_id>
# Creates an EFS filesystem tagged for this job. Prints the filesystem ID.
# -----------------------------------------------------------------------------
efs_create() {
  local job_id="$1"
  local token
  token="burstlab-ephemeral-${job_id}-$(date +%s)"

  aws efs create-file-system \
    --creation-token "$token" \
    --performance-mode generalPurpose \
    --throughput-mode bursting \
    --encrypted \
    --tags \
      "Key=Name,Value=burstlab-ephemeral-${job_id}" \
      "Key=BurstLabJob,Value=${job_id}" \
      "Key=BurstLabEphemeral,Value=true" \
      "Key=Project,Value=burstlab" \
    --region "${AWS_REGION}" \
    --query 'FileSystemId' \
    --output text
}

# -----------------------------------------------------------------------------
# efs_add_mount_target <efs_id> <subnet_id> <sg_id>
# Adds an NFS mount target for the given subnet.
# -----------------------------------------------------------------------------
efs_add_mount_target() {
  local efs_id="$1"
  local subnet_id="${2:-${CLOUD_SUBNET_A_ID}}"
  local sg_id="${3:-${EFS_SG_ID}}"

  aws efs create-mount-target \
    --file-system-id "$efs_id" \
    --subnet-id "$subnet_id" \
    --security-groups "$sg_id" \
    --region "${AWS_REGION}" \
    --query 'MountTargetId' \
    --output text
}

# -----------------------------------------------------------------------------
# efs_wait_available <efs_id> [max_attempts]
# Polls until the filesystem lifecycle state is 'available'. Default 30 attempts.
# -----------------------------------------------------------------------------
efs_wait_available() {
  local efs_id="$1"
  local max="${2:-30}"

  echo "Waiting for EFS ${efs_id} to become available..."
  for attempt in $(seq 1 "$max"); do
    local state
    state=$(aws efs describe-file-systems \
      --file-system-id "$efs_id" \
      --region "${AWS_REGION}" \
      --query 'FileSystems[0].LifeCycleState' \
      --output text 2>/dev/null || echo "error")

    if [ "$state" = "available" ]; then
      echo "EFS ${efs_id} is available (attempt ${attempt})"
      return 0
    fi
    echo "  attempt ${attempt}/${max}: state=${state} — waiting 10s..."
    sleep 10
  done

  echo "ERROR: EFS ${efs_id} did not become available after ${max} attempts" >&2
  return 1
}

# -----------------------------------------------------------------------------
# efs_wait_mount_target <efs_id> [max_attempts]
# Polls until all mount targets for the filesystem are 'available'.
# -----------------------------------------------------------------------------
efs_wait_mount_target() {
  local efs_id="$1"
  local max="${2:-30}"

  echo "Waiting for EFS ${efs_id} mount targets..."
  for attempt in $(seq 1 "$max"); do
    local not_available
    not_available=$(aws efs describe-mount-targets \
      --file-system-id "$efs_id" \
      --region "${AWS_REGION}" \
      --query 'MountTargets[?LifeCycleState!=`available`].MountTargetId' \
      --output text 2>/dev/null || echo "error")

    if [ -z "$not_available" ] || [ "$not_available" = "None" ]; then
      echo "All mount targets available (attempt ${attempt})"
      return 0
    fi
    echo "  attempt ${attempt}/${max}: waiting for mount targets... ${not_available}"
    sleep 10
  done

  echo "ERROR: mount targets did not become available" >&2
  return 1
}

# -----------------------------------------------------------------------------
# efs_destroy <efs_id>
# Deletes all mount targets then the filesystem. Polls until mount targets
# are fully deleted before calling DeleteFileSystem.
# -----------------------------------------------------------------------------
efs_destroy() {
  local efs_id="$1"

  echo "Destroying EFS ${efs_id}..."

  # Delete all mount targets
  local mount_targets
  mount_targets=$(aws efs describe-mount-targets \
    --file-system-id "$efs_id" \
    --region "${AWS_REGION}" \
    --query 'MountTargets[].MountTargetId' \
    --output text 2>/dev/null || echo "")

  for mt in $mount_targets; do
    echo "  Deleting mount target ${mt}..."
    aws efs delete-mount-target \
      --mount-target-id "$mt" \
      --region "${AWS_REGION}" 2>/dev/null || true
  done

  # Wait for mount targets to be fully deleted (required before DeleteFileSystem)
  echo "Waiting for mount targets to be deleted..."
  for attempt in $(seq 1 30); do
    local count
    count=$(aws efs describe-mount-targets \
      --file-system-id "$efs_id" \
      --region "${AWS_REGION}" \
      --query 'length(MountTargets)' \
      --output text 2>/dev/null || echo "0")

    if [ "$count" = "0" ] || [ "$count" = "None" ]; then
      echo "  All mount targets deleted (attempt ${attempt})"
      break
    fi
    echo "  attempt ${attempt}/30: ${count} mount targets remaining — waiting 10s..."
    sleep 10
  done

  # Delete the filesystem
  aws efs delete-file-system \
    --file-system-id "$efs_id" \
    --region "${AWS_REGION}"

  echo "EFS ${efs_id} destroyed."
}

# -----------------------------------------------------------------------------
# resolve_state_file [granularity] [campaign_name]
# Returns the path to the state file for the given granularity mode.
# State files are stored on the permanent cluster EFS so all jobs can read them.
# -----------------------------------------------------------------------------
resolve_state_file() {
  local granularity="${1:-${GRANULARITY:-per-job}}"
  local campaign="${2:-${CAMPAIGN_NAME:-default}}"

  mkdir -p "${EFS_STATE_DIR}"

  case "$granularity" in
    per-job)
      # JOB_REF is set by job1 when running inline (not under Slurm)
      local job_key="${SLURM_JOB_ID:-${JOB_REF:-$(date +%s)}}"
      echo "${EFS_STATE_DIR}/job-${job_key}.env"
      ;;
    per-array)
      # Use the array job ID so all tasks share the same state file
      local array_key="${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-${JOB_REF:-$(date +%s)}}}"
      echo "${EFS_STATE_DIR}/array-${array_key}.env"
      ;;
    per-campaign)
      echo "${EFS_STATE_DIR}/campaign-${campaign}.env"
      ;;
    *)
      echo "WARNING: unknown granularity '${granularity}', defaulting to per-job" >&2
      echo "${EFS_STATE_DIR}/job-${SLURM_JOB_ID:-unknown}.env"
      ;;
  esac
}
