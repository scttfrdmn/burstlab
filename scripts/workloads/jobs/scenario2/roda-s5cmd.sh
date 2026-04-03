#!/bin/bash
# =============================================================================
# scenario2/roda-s5cmd.sh — Read RODA dataset via s5cmd, write results to S3
#
# Demonstrates: "data is already in AWS" pattern using s5cmd for maximum
# S3 throughput. s5cmd handles multipart downloads transparently and is
# significantly faster than aws s3 cp for large files.
#
# SA talking point: "The NOAA GOES-16 satellite data is a public RODA dataset
# in S3. The burst node reads it directly — no data movement from on-prem.
# s5cmd saturates the network link at ~10 Gbps. Results go to the customer's
# S3 bucket immediately — no waiting for a copy back."
#
# Required environment variables (set via #SBATCH --export or environment):
#   RODA_BUCKET    — source RODA bucket (e.g. noaa-goes16)
#   RESULTS_BUCKET — destination bucket for job output
#   AWS_REGION     — AWS region
#
# Usage:
#   RODA_BUCKET=noaa-goes16 RESULTS_BUCKET=my-results AWS_REGION=us-west-2 \
#     sbatch /opt/slurm/etc/workloads/jobs/scenario2/roda-s5cmd.sh
# =============================================================================

#SBATCH --job-name=roda-s5cmd
#SBATCH --partition=aws
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=16G
#SBATCH --time=00:30:00
#SBATCH --output=/u/home/alice/logs/roda-s5cmd-%j.out
#SBATCH --error=/u/home/alice/logs/roda-s5cmd-%j.err

set -euo pipefail
mkdir -p /u/home/alice/logs

RODA_BUCKET="${RODA_BUCKET:-noaa-goes16}"
RESULTS_BUCKET="${RESULTS_BUCKET:?RESULTS_BUCKET must be set}"
AWS_REGION="${AWS_REGION:-us-west-2}"

echo "=== RODA s5cmd Demo: started: $(date) ==="
echo "  Job ID:         ${SLURM_JOB_ID}"
echo "  Node:           ${SLURMD_NODENAME:-$(hostname)}"
echo "  RODA bucket:    s3://${RODA_BUCKET}"
echo "  Results bucket: s3://${RESULTS_BUCKET}"

# Verify s5cmd is available
if ! command -v s5cmd &>/dev/null; then
  echo "ERROR: s5cmd not found. Run base layer: terraform apply in workloads/base/" >&2
  exit 1
fi

WORKDIR="/tmp/roda-${SLURM_JOB_ID}"
mkdir -p "${WORKDIR}/input" "${WORKDIR}/results"

# -----------------------------------------------------------------------------
# Step 1: Show what's in the RODA bucket (list a prefix)
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 1: List RODA dataset ==="
# NOAA GOES-16: ABI Level-2 Cloud and Moisture Imagery products
RODA_PREFIX="ABI-L2-CMIPF/2024/001/00/"
echo "Listing s3://${RODA_BUCKET}/${RODA_PREFIX} ..."
s5cmd ls "s3://${RODA_BUCKET}/${RODA_PREFIX}" | head -20 || {
  echo "Could not list prefix. Trying bucket root..."
  s5cmd ls "s3://${RODA_BUCKET}/" | head -10
  RODA_PREFIX=""
}

# -----------------------------------------------------------------------------
# Step 2: Download a sample of the dataset using s5cmd (parallel, multipart)
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 2: Download sample files via s5cmd ==="
echo "s5cmd: $(s5cmd version)"

# Download first 3 files from the prefix (demo-appropriate size)
DOWNLOAD_START=$(date +%s)
s5cmd cp \
  --concurrency 32 \
  "s3://${RODA_BUCKET}/${RODA_PREFIX}*" \
  "${WORKDIR}/input/" 2>/dev/null | head -20 || {
    echo "Prefix download done or empty — checking download..."
  }
DOWNLOAD_END=$(date +%s)
DOWNLOAD_ELAPSED=$((DOWNLOAD_END - DOWNLOAD_START))

DOWNLOADED_SIZE=$(du -sh "${WORKDIR}/input/" | cut -f1)
DOWNLOADED_FILES=$(ls "${WORKDIR}/input/" | wc -l)
echo "  Downloaded: ${DOWNLOADED_FILES} files, ${DOWNLOADED_SIZE} in ${DOWNLOAD_ELAPSED}s"

# -----------------------------------------------------------------------------
# Step 3: Process the data (demonstrate actual compute on cloud data)
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 3: Process data ==="
# For GOES-16 NetCDF files: extract metadata and statistics
# For demo purposes: compute file checksums and basic stats
for f in "${WORKDIR}/input/"*; do
  [ -f "$f" ] || continue
  echo "Processing: $(basename $f)"
  # File info
  SIZE=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
  MD5=$(md5sum "$f" 2>/dev/null | awk '{print $1}' || md5 -q "$f")
  echo "  Size: ${SIZE} bytes, MD5: ${MD5}" | tee -a "${WORKDIR}/results/summary.txt"
done

# Add job metadata to results
cat >> "${WORKDIR}/results/summary.txt" << EOF

=== Job Metadata ===
Job ID:         ${SLURM_JOB_ID}
Node:           ${SLURMD_NODENAME:-$(hostname)}
RODA Bucket:    s3://${RODA_BUCKET}/${RODA_PREFIX}
Files:          ${DOWNLOADED_FILES}
Total size:     ${DOWNLOADED_SIZE}
Download time:  ${DOWNLOAD_ELAPSED}s
Completed:      $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# -----------------------------------------------------------------------------
# Step 4: Write results directly to S3 via s5cmd
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 4: Write results to S3 ==="
RESULTS_PREFIX="roda-job-${SLURM_JOB_ID}/"

s5cmd cp \
  --concurrency 8 \
  "${WORKDIR}/results/" \
  "s3://${RESULTS_BUCKET}/${RESULTS_PREFIX}"

echo "  Results at: s3://${RESULTS_BUCKET}/${RESULTS_PREFIX}"
s5cmd ls "s3://${RESULTS_BUCKET}/${RESULTS_PREFIX}"

# Cleanup local working directory (data lives in S3)
rm -rf "${WORKDIR}"

echo ""
echo "=== RODA s5cmd Demo: COMPLETE ==="
echo "  Total time:     $(($(date +%s) - DOWNLOAD_START))s"
echo "  Data source:    s3://${RODA_BUCKET}/ (public, no egress cost)"
echo "  Results:        s3://${RESULTS_BUCKET}/${RESULTS_PREFIX}"
