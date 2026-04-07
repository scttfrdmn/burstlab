#!/bin/bash
# =============================================================================
# scenario4/prolog-epilog/example-job.sh — Example job for prolog/epilog approach
#
# Submit with standard sbatch:
#   sbatch --partition=aws example-job.sh
#
# The PrologSlurmctld intercepts #SBATCH --comment=fsx:1200, creates the FSx
# filesystem while the job is in CF state, injects FSX_STATE_FILE, then lets
# the job run. The EpilogSlurmctld flushes results to S3 and destroys FSx
# after the job completes.
#
# No wrapper needed. No chain to manage. The comment is the only addition
# to a standard job script.
# =============================================================================

#SBATCH --job-name=fsx-workload
#SBATCH --partition=aws
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --time=01:00:00
#SBATCH --comment=fsx:1200
#SBATCH --output=/home/alice/logs/fsx-workload-%j.out
#SBATCH --error=/home/alice/logs/fsx-workload-%j.err

# Derive state file path from job ID (deterministic, no env injection needed).
# scontrol update Environment= is not supported in Slurm 22.05; the prolog
# writes the state file to a well-known NFS path instead.
FSX_STATE_FILE="/opt/slurm/var/fsx-state/${USER}/job-${SLURM_JOB_ID}.env"
export FSX_STATE_FILE

# The prolog writes the state file on the head node moments before this job
# starts on the compute node. Poll up to 30s for NFS attr cache to propagate.
for _i in $(seq 1 30); do
  [ -f "$FSX_STATE_FILE" ] && break
  sleep 1
done

if [ ! -f "$FSX_STATE_FILE" ]; then
  echo "ERROR: state file not found after 30s: $FSX_STATE_FILE" >&2
  exit 1
fi
# set -a exports all variables set by the source, so exec'd child inherits them
set -a
# shellcheck source=/dev/null
source "$FSX_STATE_FILE"
set +a
exec /opt/slurm/etc/workloads/jobs/scenario4/job2-run-workload.sh
