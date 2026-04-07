#!/bin/bash
# =============================================================================
# scenario3/prolog-epilog/example-job.sh — Example job for prolog/epilog approach
#
# Submit with:
#   sbatch --partition=aws example-job.sh
#
# The PrologSlurmctld sees #SBATCH --comment=efs, creates the EFS filesystem
# (~60s), injects EFS_STATE_FILE, then the job runs. Epilog destroys EFS.
# =============================================================================

#SBATCH --job-name=efs-workload
#SBATCH --partition=aws
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --time=01:00:00
#SBATCH --comment=efs
#SBATCH --output=/home/alice/logs/efs-workload-%j.out
#SBATCH --error=/home/alice/logs/efs-workload-%j.err

# Derive state file path from job ID (deterministic, no env injection needed).
# scontrol update Environment= is not supported in Slurm 22.05; the prolog
# writes the state file to a well-known NFS path instead.
EFS_STATE_FILE="/opt/slurm/var/efs-state/${USER}/job-${SLURM_JOB_ID}.env"
export EFS_STATE_FILE

# Poll up to 30s for NFS attr cache to propagate the prolog's state file.
for _i in $(seq 1 30); do
  [ -f "$EFS_STATE_FILE" ] && break
  sleep 1
done

if [ ! -f "$EFS_STATE_FILE" ]; then
  echo "ERROR: state file not found after 30s: $EFS_STATE_FILE" >&2
  exit 1
fi
# set -a exports all variables set by the source, so exec'd child inherits them
set -a
# shellcheck source=/dev/null
source "$EFS_STATE_FILE"
set +a
exec /opt/slurm/etc/workloads/jobs/scenario3/job2-run-workload.sh
