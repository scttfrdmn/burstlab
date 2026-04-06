#!/bin/bash
# =============================================================================
# scenario4/campaign-list.sh — List all FSx campaigns (active and completed)
#
# Shows two sections:
#   ACTIVE    — FSx filesystems currently running (from ~/.fsx-state/*.env)
#   COMPLETED — Previous chains whose FSx has been destroyed (from ~/.fsx-campaigns/*.ref)
#
# Usage:
#   bash campaign-list.sh                   # list all campaigns
#   bash campaign-list.sh --details         # include S3 object counts
# =============================================================================

set -euo pipefail

STATE_DIR="${HOME}/.fsx-state"
CAMPAIGN_DIR="${HOME}/.fsx-campaigns"
SHOW_DETAILS=false

if [[ "${1:-}" == "--details" ]]; then
  SHOW_DETAILS=true
fi

HAS_ACTIVE=false
HAS_COMPLETED=false

# -------------------------------------------------------------------------
# ACTIVE campaigns (FSx currently running)
# -------------------------------------------------------------------------
if [ -d "${STATE_DIR}" ] && ls "${STATE_DIR}"/*.env &>/dev/null; then
  echo "=== Active (FSx running) ==="
  echo ""
  printf "%-25s %-24s %-14s %-50s\n" "REF" "FSX_ID" "STATE" "S3 PREFIX"
  printf "%-25s %-24s %-14s %-50s\n" "---" "------" "-----" "---------"

  for state_file in "${STATE_DIR}"/*.env; do
    [ -f "$state_file" ] || continue

    FSX_ID="" S3_DATA_BUCKET="" S3_PREFIX="" AWS_REGION="" CREATED_BY_JOB="" GRANULARITY=""
    # shellcheck source=/dev/null
    source "$state_file"

    # Check if the FSx filesystem is actually alive
    FSX_STATE=$(aws fsx describe-file-systems \
      --file-system-ids "${FSX_ID}" \
      --region "${AWS_REGION:-us-west-2}" \
      --query 'FileSystems[0].Lifecycle' \
      --output text 2>/dev/null || echo "not-found")

    REF_NAME="${CREATED_BY_JOB:-$(basename "$state_file" .env)}"
    S3_LOC="${S3_PREFIX:-unknown}"

    printf "%-25s %-24s %-14s %-50s\n" "${REF_NAME}" "${FSX_ID}" "${FSX_STATE}" "${S3_LOC}"

    if $SHOW_DETAILS && [ -n "${S3_DATA_BUCKET}" ]; then
      OBJ_COUNT=$(aws s3 ls "s3://${S3_DATA_BUCKET}/${S3_PREFIX}/" \
        --recursive --region "${AWS_REGION:-us-west-2}" 2>/dev/null | wc -l || echo 0)
      echo "  S3 objects: ${OBJ_COUNT} in s3://${S3_DATA_BUCKET}/${S3_PREFIX}/"
    fi
    HAS_ACTIVE=true
  done
  echo ""
fi

# -------------------------------------------------------------------------
# COMPLETED campaigns (FSx destroyed, data in S3)
# -------------------------------------------------------------------------
if [ -d "${CAMPAIGN_DIR}" ] && ls "${CAMPAIGN_DIR}"/*.ref &>/dev/null; then
  echo "=== Completed (FSx destroyed, data in S3) ==="
  echo ""
  printf "%-25s %-12s %-50s\n" "CAMPAIGN" "COMPLETED" "S3 OUTPUT"
  printf "%-25s %-12s %-50s\n" "--------" "---------" "---------"

  for ref_file in "${CAMPAIGN_DIR}"/*.ref; do
    [ -f "$ref_file" ] || continue

    CAMPAIGN_NAME="" S3_DATA_BUCKET="" S3_PREFIX="" RESULTS_BUCKET="" COMPLETED_AT="" AWS_REGION=""
    # shellcheck source=/dev/null
    source "$ref_file"

    COMPLETED_SHORT="${COMPLETED_AT:0:10}"
    S3_URI="s3://${S3_DATA_BUCKET}/${S3_PREFIX}/output/"

    printf "%-25s %-12s %-50s\n" "${CAMPAIGN_NAME}" "${COMPLETED_SHORT}" "${S3_URI}"

    if $SHOW_DETAILS; then
      OBJ_COUNT=$(aws s3 ls "${S3_URI}" --recursive --region "${AWS_REGION}" 2>/dev/null | wc -l || echo 0)
      echo "  Data bucket objects: ${OBJ_COUNT}"
      if [ "${RESULTS_BUCKET}" != "none" ] && [ -n "${RESULTS_BUCKET}" ]; then
        RESULTS_URI="s3://${RESULTS_BUCKET}/campaigns/${CAMPAIGN_NAME}/"
        RESULTS_COUNT=$(aws s3 ls "${RESULTS_URI}" --recursive --region "${AWS_REGION}" 2>/dev/null | wc -l || echo 0)
        echo "  Results bucket:      ${RESULTS_URI} (${RESULTS_COUNT} objects)"
      fi
      echo ""
    fi
    HAS_COMPLETED=true
  done
  echo ""
fi

if ! $HAS_ACTIVE && ! $HAS_COMPLETED; then
  echo "No campaigns found. Run a scenario 4 job chain first."
  echo "  bash /opt/slurm/etc/workloads/jobs/scenario4/submit-chain.sh"
  exit 0
fi

echo "---"
echo "Restore a campaign:  bash submit-chain-restore.sh --campaign-name <NAME>"
echo "Delete a campaign:   bash campaign-purge.sh --campaign-name <NAME>"
echo "Show S3 details:     bash campaign-list.sh --details"
