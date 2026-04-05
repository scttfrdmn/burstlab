#!/bin/bash
# =============================================================================
# scenario4/prolog-epilog/example-job.sh — Example job for prolog/epilog approach
#
# Submit with standard sbatch:
#   sbatch --partition=aws example-job.sh
#
# The SlurmctldProlog intercepts #SBATCH --comment=fsx:1200, creates the FSx
# filesystem while the job is in CF state, injects FSX_STATE_FILE, then lets
# the job run. The SlurmctldEpilog flushes results to S3 and destroys FSx
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

# FSX_STATE_FILE is injected by SlurmctldProlog via scontrol update Environment=
# The workload script sources it to get FSX_ID, FSX_DNS, etc.
exec /opt/slurm/etc/workloads/jobs/scenario4/job2-run-workload.sh
