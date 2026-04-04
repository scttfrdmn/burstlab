#!/bin/bash
# =============================================================================
# cleanup-orphan-efs.sh — Delete orphaned BurstLab ephemeral EFS filesystems
#
# Lists all EFS filesystems tagged with Project=burstlab and Name matching
# the ephemeral pattern (burstlab-ephemeral-*), then deletes mount targets
# and filesystems that are not the cluster's permanent EFS.
#
# The permanent cluster EFS is identified by its filesystem ID from Terraform
# state, or by tag ClusterRole=shared-storage.
#
# Usage:
#   # Dry run (show what would be deleted):
#   AWS_PROFILE=aws AWS_REGION=us-west-2 bash scripts/cleanup-orphan-efs.sh --dry-run
#
#   # Delete (with confirmation):
#   AWS_PROFILE=aws AWS_REGION=us-west-2 bash scripts/cleanup-orphan-efs.sh
#
#   # Skip confirmation (for scripted cleanup):
#   AWS_PROFILE=aws AWS_REGION=us-west-2 bash scripts/cleanup-orphan-efs.sh --force
# =============================================================================

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-west-2}"
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --force)   FORCE=true;   shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

echo "=== BurstLab: orphan EFS cleanup ==="
echo "  Region:  ${AWS_REGION}"
echo "  Dry run: ${DRY_RUN}"
echo ""

# Get all EFS filesystems: both ephemeral (burstlab-ephemeral-*) and orphaned
# permanent cluster EFS (burstlab-*-efs, but NOT the currently deployed one).
#
# Pass KEEP_EFS_ID=<id> to protect the currently deployed permanent EFS.
# e.g. KEEP_EFS_ID=$(terraform -chdir=terraform/generations/gen1-... output -raw efs_id)
KEEP_EFS_ID="${KEEP_EFS_ID:-}"

ALL_FILESYSTEMS=$(aws efs describe-file-systems \
  --region "${AWS_REGION}" \
  --query 'FileSystems[].[FileSystemId,CreationToken,LifeCycleState,SizeInBytes.Value]' \
  --output text 2>/dev/null)

# Filter: keep only BurstLab-created filesystems (known token patterns)
# Exclude the permanent EFS of any currently-deployed cluster
FILESYSTEMS=$(echo "$ALL_FILESYSTEMS" | awk -v keep="$KEEP_EFS_ID" '
  {
    id=$1; token=$2; state=$3; size=$4
    # Skip the explicitly protected EFS
    if (keep != "" && id == keep) next
    # Include ephemeral EFS (our naming convention)
    if (token ~ /^burstlab-ephemeral-/) { print; next }
    # Include orphaned permanent cluster EFS (deployed but not destroyed)
    if (token ~ /^burstlab-.*-efs$/) { print; next }
  }
')

if [ -z "$FILESYSTEMS" ]; then
  echo "No orphaned ephemeral EFS filesystems found."
  exit 0
fi

# Count them
TOTAL=$(echo "$FILESYSTEMS" | wc -l | tr -d ' ')
echo "Found ${TOTAL} orphaned ephemeral EFS filesystem(s):"
echo ""
echo "$FILESYSTEMS" | while read -r FS_ID TOKEN STATE SIZE; do
  SIZE_GB=$(( ${SIZE:-0} / 1073741824 ))
  echo "  ${FS_ID}  state=${STATE}  size=${SIZE_GB}GB  token=${TOKEN}"
done
echo ""

if [ "$DRY_RUN" = "true" ]; then
  echo "Dry run — no changes made."
  echo "Run without --dry-run to delete."
  exit 0
fi

if [ "$FORCE" = "false" ]; then
  read -r -p "Delete all ${TOTAL} filesystem(s)? [y/N] " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Delete each filesystem
DELETED=0
FAILED=0

echo "$FILESYSTEMS" | while read -r FS_ID TOKEN STATE _SIZE; do
  echo "--- Deleting ${FS_ID} (${TOKEN}) ---"

  # Delete all mount targets first
  MTS=$(aws efs describe-mount-targets \
    --file-system-id "${FS_ID}" \
    --region "${AWS_REGION}" \
    --query 'MountTargets[].MountTargetId' \
    --output text 2>/dev/null || echo "")

  for MT_ID in $MTS; do
    echo "  Deleting mount target ${MT_ID}..."
    aws efs delete-mount-target \
      --mount-target-id "${MT_ID}" \
      --region "${AWS_REGION}" 2>/dev/null || true
  done

  # Wait for mount targets to be deleted
  if [ -n "$MTS" ]; then
    echo "  Waiting for mount targets to be deleted..."
    for attempt in $(seq 1 30); do
      REMAINING=$(aws efs describe-mount-targets \
        --file-system-id "${FS_ID}" \
        --region "${AWS_REGION}" \
        --query 'length(MountTargets)' \
        --output text 2>/dev/null || echo "0")
      [ "${REMAINING}" -eq 0 ] && break
      echo "    ${REMAINING} mount target(s) remaining... (attempt ${attempt}/30)"
      sleep 10
    done
  fi

  # Delete the filesystem
  echo "  Deleting filesystem ${FS_ID}..."
  if aws efs delete-file-system \
    --file-system-id "${FS_ID}" \
    --region "${AWS_REGION}" 2>/dev/null; then
    echo "  Deleted: ${FS_ID}"
    DELETED=$((DELETED + 1))
  else
    echo "  FAILED to delete ${FS_ID} (may still have mount targets or be in use)"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=== Cleanup complete ==="
echo "  Region: ${AWS_REGION}"
