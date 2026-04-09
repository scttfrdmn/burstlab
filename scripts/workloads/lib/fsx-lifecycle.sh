#!/bin/bash
# =============================================================================
# lib/fsx-lifecycle.sh — Shared FSx Lustre lifecycle functions for Scenario 4
#
# Source this file in job scripts:
#   source /opt/slurm/etc/workloads/lib/fsx-lifecycle.sh
#
# Provides:
#   fsx_create           — Create FSx Lustre filesystem linked to S3
#   fsx_wait_available   — Poll until filesystem is in 'AVAILABLE' state
#   fsx_get_dns          — Return the DNS name for mounting
#   fsx_flush_to_s3      — Create a data repository export task
#   fsx_wait_export      — Poll until the export task completes
#   fsx_destroy          — Delete the FSx filesystem
#   resolve_fsx_state_file — Return state file path for given granularity
#
# Required environment variables:
#   AWS_REGION          — AWS region
#   BURST_SUBNET_ID   — Subnet for the FSx filesystem
#   FSX_SG_ID           — Security group (must allow Lustre ports from VPC)
#   S3_DATA_BUCKET      — S3 bucket for the data repository
#   GRANULARITY         — per-job | per-array | per-campaign
#   CAMPAIGN_NAME       — only required when GRANULARITY=per-campaign
#
# Optional:
#   FSX_STORAGE_GB      — FSx storage capacity in GB (default: 1200, minimum for SCRATCH_2)
#   S3_DATA_PREFIX      — S3 prefix for the data repository (default: "data/")
#
# Cost reference (SCRATCH_2, us-west-2):
#   $0.14/GB-month = $0.000194/GB-hour
#   1200 GB × 24h = $5.58/day — destroy when the job ends!
# =============================================================================

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-west-2}"
FSX_STATE_DIR="${FSX_STATE_DIR:-/home/alice/.fsx-state}"
FSX_STORAGE_GB="${FSX_STORAGE_GB:-1200}"
S3_DATA_PREFIX="${S3_DATA_PREFIX:-data/}"

# -----------------------------------------------------------------------------
# fsx_create <job_id> <s3_bucket> [s3_prefix] [subnet_id] [sg_id] [storage_gb]
# Creates a SCRATCH_2 FSx Lustre filesystem with S3 data repository association.
# Prints the filesystem ID.
#
# SCRATCH_2: highest throughput scratch tier, no data retention after deletion,
# supports S3 data repository association for lazy import and export.
# -----------------------------------------------------------------------------
fsx_create() {
  local job_id="$1"
  local s3_bucket="${2:-${S3_DATA_BUCKET}}"
  local s3_prefix="${3:-${S3_DATA_PREFIX}}"
  local subnet_id="${4:-${BURST_SUBNET_ID}}"
  local sg_id="${5:-${FSX_SG_ID}}"
  local storage_gb="${6:-${FSX_STORAGE_GB}}"

  # SCRATCH_2 minimum is 1200 GB; enforce it
  if [ "$storage_gb" -lt 1200 ]; then
    echo "WARNING: SCRATCH_2 minimum is 1200 GB, adjusting from ${storage_gb}" >&2
    storage_gb=1200
  fi

  # Print cost estimate before creating (stderr — stdout is reserved for the filesystem ID)
  local hourly_cost
  hourly_cost=$(awk "BEGIN { printf \"%.2f\", ${storage_gb} * 0.14 / 730 }")
  echo "Creating FSx Lustre SCRATCH_2: ${storage_gb} GB @ \$${hourly_cost}/hr" >&2
  echo "  S3 data repository: s3://${s3_bucket}/${s3_prefix}" >&2
  echo "  Subnet: ${subnet_id}" >&2

  aws fsx create-file-system \
    --file-system-type LUSTRE \
    --file-system-type-version "2.15" \
    --storage-capacity "$storage_gb" \
    --storage-type SSD \
    --subnet-ids "$subnet_id" \
    --security-group-ids "$sg_id" \
    --lustre-configuration "{
      \"ImportPath\": \"s3://${s3_bucket}/${s3_prefix}\",
      \"ExportPath\": \"s3://${s3_bucket}/${s3_prefix}\",
      \"DeploymentType\": \"SCRATCH_2\",
      \"AutoImportPolicy\": \"NEW_CHANGED\"
    }" \
    --tags \
      "Key=Name,Value=burstlab-ephemeral-${job_id}" \
      "Key=BurstLabJob,Value=${job_id}" \
      "Key=BurstLabEphemeral,Value=true" \
      "Key=Project,Value=burstlab" \
    --region "${AWS_REGION}" \
    --query 'FileSystem.FileSystemId' \
    --output text
}

# -----------------------------------------------------------------------------
# fsx_wait_available <fsx_id> [max_attempts]
# FSx creation typically takes 5-10 minutes but can reach 20 min. Default: 80 × 15s = 20 min.
# -----------------------------------------------------------------------------
fsx_wait_available() {
  local fsx_id="$1"
  local max="${2:-80}"

  echo "Waiting for FSx ${fsx_id} to become AVAILABLE (typically 5-10 min)..."
  for attempt in $(seq 1 "$max"); do
    local state
    state=$(aws fsx describe-file-systems \
      --file-system-ids "$fsx_id" \
      --region "${AWS_REGION}" \
      --query 'FileSystems[0].Lifecycle' \
      --output text 2>/dev/null || echo "error")

    case "$state" in
      AVAILABLE)
        echo "FSx ${fsx_id} is AVAILABLE (attempt ${attempt})"
        return 0
        ;;
      FAILED|MISCONFIGURED)
        echo "ERROR: FSx ${fsx_id} is in state ${state}" >&2
        aws fsx describe-file-systems \
          --file-system-ids "$fsx_id" \
          --region "${AWS_REGION}" \
          --query 'FileSystems[0].FailureDetails' >&2 || true
        return 1
        ;;
    esac
    echo "  attempt ${attempt}/${max}: state=${state} — waiting 15s..."
    sleep 15
  done

  echo "ERROR: FSx ${fsx_id} did not become AVAILABLE after ${max} attempts" >&2
  return 1
}

# -----------------------------------------------------------------------------
# fsx_get_dns <fsx_id>
# Returns the DNS name for mounting the FSx filesystem.
# -----------------------------------------------------------------------------
fsx_get_dns() {
  local fsx_id="$1"
  aws fsx describe-file-systems \
    --file-system-ids "$fsx_id" \
    --region "${AWS_REGION}" \
    --query 'FileSystems[0].DNSName' \
    --output text
}

# -----------------------------------------------------------------------------
# fsx_flush_to_s3 <fsx_id> [path_prefix]
# Creates a data repository export task to flush Lustre data back to S3.
# Returns the task ID.
# Call fsx_wait_export after this to confirm completion before destroying.
# -----------------------------------------------------------------------------
fsx_flush_to_s3() {
  local fsx_id="$1"
  local path_prefix="${2:-/}"

  echo "Flushing FSx ${fsx_id} path '${path_prefix}' to S3..." >&2
  aws fsx create-data-repository-task \
    --file-system-id "$fsx_id" \
    --type EXPORT_TO_REPOSITORY \
    --paths "$path_prefix" \
    --report '{"Enabled": false}' \
    --region "${AWS_REGION}" \
    --query 'DataRepositoryTask.TaskId' \
    --output text
}

# -----------------------------------------------------------------------------
# fsx_wait_export <fsx_id> <task_id> [max_attempts]
# Polls until the export task reaches SUCCEEDED or FAILED. Default: 60 × 30s = 30 min.
# -----------------------------------------------------------------------------
fsx_wait_export() {
  local fsx_id="$1"
  local task_id="$2"
  local max="${3:-60}"

  echo "Waiting for FSx export task ${task_id} to complete..."
  for attempt in $(seq 1 "$max"); do
    local status
    status=$(aws fsx describe-data-repository-tasks \
      --task-ids "$task_id" \
      --region "${AWS_REGION}" \
      --query 'DataRepositoryTasks[0].Lifecycle' \
      --output text 2>/dev/null || echo "error")

    case "$status" in
      SUCCEEDED)
        echo "Export task ${task_id} completed successfully (attempt ${attempt})"
        return 0
        ;;
      FAILED|CANCELED)
        echo "ERROR: Export task ${task_id} status: ${status}" >&2
        return 1
        ;;
    esac
    echo "  attempt ${attempt}/${max}: status=${status} — waiting 30s..."
    sleep 30
  done

  echo "ERROR: Export task ${task_id} did not complete after ${max} attempts" >&2
  return 1
}

# -----------------------------------------------------------------------------
# fsx_destroy <fsx_id>
# Deletes the FSx filesystem. Call after fsx_wait_export to ensure data is safe.
# -----------------------------------------------------------------------------
fsx_destroy() {
  local fsx_id="$1"

  echo "Destroying FSx ${fsx_id}..."
  aws fsx delete-file-system \
    --file-system-id "$fsx_id" \
    --region "${AWS_REGION}"

  echo "FSx ${fsx_id} deletion requested — billing stops immediately."
  echo "Filesystem will be fully deleted in a few minutes."
}

# -----------------------------------------------------------------------------
# resolve_fsx_state_file [granularity] [campaign_name]
# Returns the state file path for the given granularity mode.
# Mirrors efs-lifecycle.sh resolve_state_file pattern.
# -----------------------------------------------------------------------------
resolve_fsx_state_file() {
  local granularity="${1:-${GRANULARITY:-per-job}}"
  local campaign="${2:-${CAMPAIGN_NAME:-default}}"

  mkdir -p "${FSX_STATE_DIR}"

  case "$granularity" in
    per-job)
      local job_key="${SLURM_JOB_ID:-${JOB_REF:-$(date +%s)}}"
      echo "${FSX_STATE_DIR}/job-${job_key}.env"
      ;;
    per-array)
      local array_key="${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-${JOB_REF:-$(date +%s)}}}"
      echo "${FSX_STATE_DIR}/array-${array_key}.env"
      ;;
    per-campaign)
      echo "${FSX_STATE_DIR}/campaign-${campaign}.env"
      ;;
    *)
      echo "WARNING: unknown granularity '${granularity}', defaulting to per-job" >&2
      local job_key="${SLURM_JOB_ID:-${JOB_REF:-$(date +%s)}}"
      echo "${FSX_STATE_DIR}/job-${job_key}.env"
      ;;
  esac
}
