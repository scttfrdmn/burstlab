#!/bin/bash
# =============================================================================
# scenario4/campaign-purge.sh — Delete S3 data and campaign record for a campaign
#
# Removes all S3 data (data bucket + results bucket) for a given campaign and
# deletes the campaign reference file. Use this when you are done with a
# campaign's data and want to clean up S3 storage costs.
#
# Usage:
#   bash campaign-purge.sh --campaign-name <NAME>
#   bash campaign-purge.sh --campaign-name <NAME> --yes   # skip confirmation
#
# SA talking point: "The data bucket (ephemeral) and results bucket (durable)
# are separate. terraform destroy cleans up the data bucket automatically, but
# the results bucket persists — it's the customer's permanent store. This script
# is how you explicitly clean up when you're done."
# =============================================================================

set -euo pipefail

CAMPAIGN_DIR="${HOME}/.fsx-campaigns"
CAMPAIGN_NAME=""
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --campaign-name) CAMPAIGN_NAME="$2"; shift 2 ;;
    --yes)           SKIP_CONFIRM=true;  shift   ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [ -z "${CAMPAIGN_NAME}" ]; then
  echo "Usage: bash campaign-purge.sh --campaign-name <NAME>"
  echo ""
  echo "Available campaigns:"
  ls -1 "${CAMPAIGN_DIR}"/*.ref 2>/dev/null | while read -r f; do
    basename "$f" .ref
  done
  exit 1
fi

CAMPAIGN_FILE="${CAMPAIGN_DIR}/${CAMPAIGN_NAME}.ref"
if [ ! -f "${CAMPAIGN_FILE}" ]; then
  echo "Campaign '${CAMPAIGN_NAME}' not found at ${CAMPAIGN_FILE}"
  exit 1
fi

# Read campaign record
S3_DATA_BUCKET="" S3_PREFIX="" RESULTS_BUCKET="" AWS_REGION=""
# shellcheck source=/dev/null
source "${CAMPAIGN_FILE}"

echo "=== Purge Campaign: ${CAMPAIGN_NAME} ==="
echo "  Data bucket:    s3://${S3_DATA_BUCKET}/${S3_PREFIX}/"
if [ "${RESULTS_BUCKET}" != "none" ] && [ -n "${RESULTS_BUCKET}" ]; then
  echo "  Results bucket: s3://${RESULTS_BUCKET}/campaigns/${CAMPAIGN_NAME}/"
fi
echo ""

if ! $SKIP_CONFIRM; then
  read -rp "Delete all S3 data for this campaign? [y/N] " REPLY
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Delete from data bucket
echo "Deleting from data bucket: s3://${S3_DATA_BUCKET}/${S3_PREFIX}/..."
aws s3 rm "s3://${S3_DATA_BUCKET}/${S3_PREFIX}/" \
  --recursive --region "${AWS_REGION}" 2>/dev/null || \
  echo "  (data bucket may already be empty or deleted)"

# Delete from results bucket
if [ "${RESULTS_BUCKET}" != "none" ] && [ -n "${RESULTS_BUCKET}" ]; then
  echo "Deleting from results bucket: s3://${RESULTS_BUCKET}/campaigns/${CAMPAIGN_NAME}/..."
  aws s3 rm "s3://${RESULTS_BUCKET}/campaigns/${CAMPAIGN_NAME}/" \
    --recursive --region "${AWS_REGION}" 2>/dev/null || \
    echo "  (results bucket may already be empty)"
fi

# Remove campaign record
rm -f "${CAMPAIGN_FILE}"
echo ""
echo "Campaign '${CAMPAIGN_NAME}' purged."
