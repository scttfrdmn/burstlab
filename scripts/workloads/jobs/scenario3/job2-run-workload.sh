#!/bin/bash
# =============================================================================
# scenario3/job2-run-workload.sh — Mount ephemeral EFS and run workload
#
# Reads the EFS ID from the state file written by Job 1, mounts the ephemeral
# EFS filesystem, runs the workload, copies results back, then unmounts.
#
# For per-array granularity: each task reads the SAME state file (keyed by
# SLURM_ARRAY_JOB_ID) and mounts the shared filesystem independently.
# Task-indexed subdirectories (input/$SLURM_ARRAY_TASK_ID/) keep tasks isolated.
#
# SA talking point: "Job 2 reads the EFS ID from the state file — that's the
# handoff from Job 1. It mounts the ephemeral EFS, runs the computation,
# and unmounts when done. Multiple array tasks would each mount the same
# filesystem and work in their own subdirectory."
# =============================================================================

#SBATCH --job-name=efs-workload
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --time=01:00:00
#SBATCH --output=/u/home/alice/logs/efs-workload-%j.out
#SBATCH --error=/u/home/alice/logs/efs-workload-%j.err

set -euo pipefail
mkdir -p /u/home/alice/logs

source /opt/slurm/etc/workloads/lib/efs-lifecycle.sh

echo "=== EFS Workload: started on $(hostname): $(date) ==="
echo "  Job ID:         ${SLURM_JOB_ID}"
echo "  Array Task ID:  ${SLURM_ARRAY_TASK_ID:-none}"
echo "  Granularity:    ${GRANULARITY}"

# Read EFS ID from state file written by Job 1
STATE_FILE=$(resolve_state_file "${GRANULARITY}" "${CAMPAIGN_NAME:-default}")
echo "  State file:     ${STATE_FILE}"

if [ ! -f "${STATE_FILE}" ]; then
  echo "ERROR: State file not found: ${STATE_FILE}" >&2
  echo "Did Job 1 complete successfully?" >&2
  exit 1
fi

source "${STATE_FILE}"
echo "  EFS ID:         ${EFS_ID}"
echo "  EFS DNS:        ${EFS_DNS}"

# Mount the ephemeral EFS
TASK_ID="${SLURM_ARRAY_TASK_ID:-0}"
MOUNT_POINT="/mnt/scratch/efs-${EFS_ID}-${SLURM_JOB_ID}-${TASK_ID}"
mkdir -p "${MOUNT_POINT}"

echo "Mounting ${EFS_DNS}:/ at ${MOUNT_POINT}..."
mount -t nfs4 \
  -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport \
  "${EFS_DNS}:/" \
  "${MOUNT_POINT}"

echo "  Mounted successfully."

# Set up per-task directories
INPUT_DIR="${MOUNT_POINT}/input/${TASK_ID}"
OUTPUT_DIR="${MOUNT_POINT}/output/${TASK_ID}"
mkdir -p "${INPUT_DIR}" "${OUTPUT_DIR}"

# Stage input data from permanent EFS to ephemeral EFS
# (simulates moving data from "on-prem" storage to ephemeral scratch)
echo ""
echo "Staging input data to ephemeral EFS..."
if [ -d "/opt/slurm/etc/workloads/data" ]; then
  cp -r /opt/slurm/etc/workloads/data/* "${INPUT_DIR}/" 2>/dev/null || true
fi

# Create synthetic demo workload input if nothing was staged
if [ -z "$(ls -A ${INPUT_DIR} 2>/dev/null)" ]; then
  echo "Generating synthetic workload input..."
  for i in $(seq 1 10); do
    dd if=/dev/urandom bs=1M count=10 2>/dev/null | base64 > "${INPUT_DIR}/data-${i}.dat"
  done
fi

INPUT_SIZE=$(du -sh "${INPUT_DIR}" | cut -f1)
echo "  Input: ${INPUT_SIZE} in ${INPUT_DIR}"

# Run workload
echo ""
echo "Running workload on ephemeral EFS scratch..."
START=$(date +%s)

# Demo workload: compute checksums of all input files (realistic I/O pattern)
for f in "${INPUT_DIR}"/*; do
  [ -f "$f" ] || continue
  CKSUM=$(md5sum "$f" | awk '{print $1}')
  echo "$(basename $f): ${CKSUM}" >> "${OUTPUT_DIR}/checksums.txt"
done

# Write job metadata
cat > "${OUTPUT_DIR}/job-metadata.txt" << EOF
Job ID:       ${SLURM_JOB_ID}
Array Task:   ${SLURM_ARRAY_TASK_ID:-none}
Node:         $(hostname)
EFS ID:       ${EFS_ID}
Input size:   ${INPUT_SIZE}
Started:      $(date -u +%Y-%m-%dT%H:%M:%SZ)
Granularity:  ${GRANULARITY}
EOF

ELAPSED=$(($(date +%s) - START))
echo "  Workload completed in ${ELAPSED}s"
echo "  Output: $(ls ${OUTPUT_DIR}/ | wc -l) files in ${OUTPUT_DIR}"

# Copy results back to permanent EFS before unmounting
RESULTS_DIR="/u/home/alice/results/efs-job-${SLURM_JOB_ID}-task-${TASK_ID}"
mkdir -p "${RESULTS_DIR}"
cp -r "${OUTPUT_DIR}"/. "${RESULTS_DIR}/"
echo "  Results copied to permanent EFS: ${RESULTS_DIR}"

# Unmount before Job 3 destroys the filesystem
echo ""
echo "Unmounting ${MOUNT_POINT}..."
umount "${MOUNT_POINT}"
rmdir "${MOUNT_POINT}"
echo "  Unmounted."

echo ""
echo "=== EFS Workload: COMPLETE ==="
echo "  Elapsed:   ${ELAPSED}s"
echo "  Results:   ${RESULTS_DIR}"
echo "  Completed: $(date)"
