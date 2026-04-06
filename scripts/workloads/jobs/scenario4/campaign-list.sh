#!/bin/bash
# =============================================================================
# scenario4/campaign-list.sh — List completed FSx campaigns and their S3 data
#
# Reads campaign completion records from ~/.fsx-campaigns/ and shows what
# S3 data exists from past FSx chains. Use this to find a campaign name
# for submit-chain-restore.sh.
#
# Usage:
#   bash campaign-list.sh                   # list all campaigns
#   bash campaign-list.sh --details         # include S3 object counts
# =============================================================================

set -euo pipefail

CAMPAIGN_DIR="${HOME}/.fsx-campaigns"
SHOW_DETAILS=false

if [[ "${1:-}" == "--details" ]]; then
  SHOW_DETAILS=true
fi

if [ ! -d "${CAMPAIGN_DIR}" ] || [ -z "$(ls -A "${CAMPAIGN_DIR}" 2>/dev/null)" ]; then
  echo "No campaigns found. Run a scenario 4 job chain first."
  echo "  bash /opt/slurm/etc/workloads/jobs/scenario4/submit-chain.sh"
  exit 0
fi

echo "=== FSx Campaigns ==="
echo ""
printf "%-25s %-12s %-50s\n" "CAMPAIGN" "COMPLETED" "S3 OUTPUT"
printf "%-25s %-12s %-50s\n" "--------" "---------" "---------"

for ref_file in "${CAMPAIGN_DIR}"/*.ref; do
  [ -f "$ref_file" ] || continue

  # Read campaign record
  CAMPAIGN_NAME="" S3_DATA_BUCKET="" S3_PREFIX="" RESULTS_BUCKET="" COMPLETED_AT="" AWS_REGION=""
  # shellcheck source=/dev/null
  source "$ref_file"

  COMPLETED_SHORT="${COMPLETED_AT:0:10}"
  S3_URI="s3://${S3_DATA_BUCKET}/${S3_PREFIX}/output/"

  printf "%-25s %-12s %-50s\n" "${CAMPAIGN_NAME}" "${COMPLETED_SHORT}" "${S3_URI}"

  if $SHOW_DETAILS; then
    # Count objects in S3 data bucket
    OBJ_COUNT=$(aws s3 ls "${S3_URI}" --recursive --region "${AWS_REGION}" 2>/dev/null | wc -l || echo 0)
    echo "  Data bucket objects: ${OBJ_COUNT}"
    if [ "${RESULTS_BUCKET}" != "none" ] && [ -n "${RESULTS_BUCKET}" ]; then
      RESULTS_URI="s3://${RESULTS_BUCKET}/campaigns/${CAMPAIGN_NAME}/"
      RESULTS_COUNT=$(aws s3 ls "${RESULTS_URI}" --recursive --region "${AWS_REGION}" 2>/dev/null | wc -l || echo 0)
      echo "  Results bucket:      ${RESULTS_URI} (${RESULTS_COUNT} objects)"
    fi
    echo ""
  fi
done

echo ""
echo "Restore a campaign:  bash submit-chain-restore.sh --campaign-name <NAME>"
echo "Delete a campaign:   bash campaign-purge.sh --campaign-name <NAME>"
echo "Show S3 details:     bash campaign-list.sh --details"
