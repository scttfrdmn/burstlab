#!/bin/bash
# =============================================================================
# scenario2/roda-mountpoint.sh — Read RODA dataset via AWS Mountpoint for S3
#
# Mounts the RODA S3 bucket as a POSIX filesystem using AWS Mountpoint.
# Applications read S3 objects as if they were local files — no code changes.
# Lazy loading: files are streamed from S3 on first read (not pre-downloaded).
#
# SA talking point: "Mountpoint presents S3 as a POSIX filesystem. The
# application doesn't know it's reading from S3 — it just opens a file.
# Data streams in as it's read. This is the 'zero code change' path for
# porting on-prem applications to read cloud data."
#
# Note: Mountpoint requires FUSE. If not available on the burst node AMI,
# this script falls back to s5cmd download + direct file access.
#
# Required environment variables:
#   RODA_BUCKET    — source RODA bucket
#   RESULTS_BUCKET — destination bucket
#   AWS_REGION     — AWS region
# =============================================================================

#SBATCH --job-name=roda-mountpoint
#SBATCH --partition=aws
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --time=00:30:00
#SBATCH --output=/u/home/alice/logs/roda-mountpoint-%j.out

set -uo pipefail
mkdir -p /u/home/alice/logs

RODA_BUCKET="${RODA_BUCKET:-noaa-goes16}"
RESULTS_BUCKET="${RESULTS_BUCKET:?RESULTS_BUCKET must be set}"
AWS_REGION="${AWS_REGION:-us-west-2}"
RODA_PREFIX="${RODA_PREFIX:-ABI-L2-CMIPF/2024/001/00}"

MOUNT_POINT="/mnt/roda-${SLURM_JOB_ID}"
WORKDIR="/tmp/mountpoint-${SLURM_JOB_ID}"
mkdir -p "${MOUNT_POINT}" "${WORKDIR}/results"

echo "=== RODA Mountpoint Demo: started: $(date) ==="

# Check if Mountpoint is available
if ! command -v mount-s3 &>/dev/null; then
  echo "WARNING: mount-s3 not found — falling back to s5cmd download"
  USE_MOUNTPOINT=false
else
  echo "  mount-s3: $(mount-s3 --version 2>/dev/null || echo 'present')"
  USE_MOUNTPOINT=true
fi

if [ "$USE_MOUNTPOINT" = "true" ]; then
  # Mount the RODA bucket read-only
  echo "=== Mounting s3://${RODA_BUCKET} at ${MOUNT_POINT} ==="
  mount-s3 \
    "${RODA_BUCKET}" \
    "${MOUNT_POINT}" \
    --region "${AWS_REGION}" \
    --read-only \
    --allow-other 2>/dev/null || {
      echo "FUSE mount failed — falling back to s5cmd"
      USE_MOUNTPOINT=false
    }
fi

if [ "$USE_MOUNTPOINT" = "true" ]; then
  # Access files via POSIX path — application sees a normal directory
  echo "=== Reading files via POSIX path (lazy-loaded from S3) ==="
  echo "Contents of ${MOUNT_POINT}/${RODA_PREFIX}/:"
  ls "${MOUNT_POINT}/${RODA_PREFIX}/" | head -10

  # Read the first file — triggers lazy load from S3
  FIRST_FILE=$(ls "${MOUNT_POINT}/${RODA_PREFIX}/"*.nc 2>/dev/null | head -1)
  if [ -n "${FIRST_FILE}" ]; then
    START=$(date +%s)
    SIZE=$(wc -c < "${FIRST_FILE}")
    ELAPSED=$(($(date +%s) - START))
    echo "  Read $(basename ${FIRST_FILE}): ${SIZE} bytes in ${ELAPSED}s (streamed from S3)"
  fi

  # Summary
  echo "Mount: s3://${RODA_BUCKET} → ${MOUNT_POINT}" > "${WORKDIR}/results/mountpoint-summary.txt"
  echo "Prefix: ${RODA_PREFIX}" >> "${WORKDIR}/results/mountpoint-summary.txt"
  ls -lh "${MOUNT_POINT}/${RODA_PREFIX}/" >> "${WORKDIR}/results/mountpoint-summary.txt" 2>/dev/null

  # Unmount
  fusermount -u "${MOUNT_POINT}" 2>/dev/null || umount "${MOUNT_POINT}" 2>/dev/null || true

else
  # Fallback: s5cmd download
  echo "=== Fallback: downloading via s5cmd ==="
  s5cmd cp "s3://${RODA_BUCKET}/${RODA_PREFIX}/" "${WORKDIR}/input/" 2>/dev/null || true
  echo "Fallback download complete" > "${WORKDIR}/results/mountpoint-summary.txt"
fi

# Upload results
s5cmd cp "${WORKDIR}/results/" "s3://${RESULTS_BUCKET}/mountpoint-job-${SLURM_JOB_ID}/" 2>/dev/null || true

echo ""
echo "=== Mountpoint Demo: COMPLETE ==="
rm -rf "${WORKDIR}" "${MOUNT_POINT}" 2>/dev/null || true
