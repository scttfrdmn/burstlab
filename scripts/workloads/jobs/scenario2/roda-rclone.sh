#!/bin/bash
# =============================================================================
# scenario2/roda-rclone.sh — Read RODA dataset via rclone with integrity check
#
# Uses rclone for S3 access with MD5 checksum verification. rclone is the
# "right" tool for researchers who care about data integrity — it verifies
# that every byte transferred matches the source checksum.
#
# SA talking point: "rclone is what most HPC sysadmins reach for when they
# want S3 access with integrity guarantees. It's slower than s5cmd but
# verifies checksums end-to-end. For genomics or observational data where
# bit-perfect transfers matter, this is the right choice."
#
# Required environment variables:
#   RODA_BUCKET    — source RODA bucket
#   RESULTS_BUCKET — destination bucket
#   AWS_REGION     — AWS region
# =============================================================================

#SBATCH --job-name=roda-rclone
#SBATCH --partition=aws
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=00:30:00
#SBATCH --output=/u/home/alice/logs/roda-rclone-%j.out

set -euo pipefail
mkdir -p /u/home/alice/logs

RODA_BUCKET="${RODA_BUCKET:-noaa-goes16}"
RESULTS_BUCKET="${RESULTS_BUCKET:?RESULTS_BUCKET must be set}"
AWS_REGION="${AWS_REGION:-us-west-2}"
RODA_PREFIX="${RODA_PREFIX:-ABI-L2-CMIPF/2024/001/00/}"

echo "=== RODA rclone Demo: started: $(date) ==="
echo "  rclone: $(rclone version | head -1)"

WORKDIR="/tmp/roda-rclone-${SLURM_JOB_ID}"
mkdir -p "${WORKDIR}/input" "${WORKDIR}/results"

# Use instance profile credentials (no explicit AWS keys needed)
export AWS_DEFAULT_REGION="${AWS_REGION}"

# rclone config: use environment auth (instance profile)
RCLONE_OPTS="--s3-provider AWS --s3-env-auth --s3-region ${AWS_REGION}"

# List the dataset
echo "=== Listing RODA source ==="
rclone ls :s3:"${RODA_BUCKET}/${RODA_PREFIX}" ${RCLONE_OPTS} 2>/dev/null | head -20

# Copy with checksum verification (--checksum flag)
echo "=== Downloading with integrity check ==="
START=$(date +%s)
rclone copy \
  :s3:"${RODA_BUCKET}/${RODA_PREFIX}" \
  "${WORKDIR}/input/" \
  ${RCLONE_OPTS} \
  --checksum \
  --transfers 16 \
  --checkers 8 \
  --progress \
  --stats 10s \
  --max-transfer 500M 2>&1

ELAPSED=$(($(date +%s) - START))
echo "  Downloaded in ${ELAPSED}s with checksum verification"

# Write results
echo "Job: ${SLURM_JOB_ID}, Source: s3://${RODA_BUCKET}/${RODA_PREFIX}, Time: ${ELAPSED}s" \
  > "${WORKDIR}/results/rclone-summary.txt"
ls -lh "${WORKDIR}/input/" >> "${WORKDIR}/results/rclone-summary.txt"

# Upload results to S3 with rclone (also checksummed)
echo "=== Uploading results to S3 ==="
rclone copy \
  "${WORKDIR}/results/" \
  :s3:"${RESULTS_BUCKET}/rclone-job-${SLURM_JOB_ID}/" \
  ${RCLONE_OPTS} \
  --checksum

echo ""
echo "=== rclone Demo: COMPLETE ==="
echo "  Results: s3://${RESULTS_BUCKET}/rclone-job-${SLURM_JOB_ID}/"
rm -rf "${WORKDIR}"
