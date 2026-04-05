#!/bin/bash
# =============================================================================
# scenario4/wrapper/example-job.sh — Example workload for fsx-sbatch wrapper
#
# Submit with:
#   fsx-sbatch example-job.sh
#   fsx-sbatch --fsx-storage=2400 example-job.sh   ← override to 2400 GB
#
# The #SBATCH --comment=fsx:1200 line is the only addition required to a
# standard job script. The wrapper intercepts this, creates FSx, injects
# FSX_STATE_FILE, and submits the real job — all transparently.
# =============================================================================

#SBATCH --job-name=fsx-workload
#SBATCH --partition=aws
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --time=01:00:00
#SBATCH --comment=fsx:1200
#SBATCH --output=/home/alice/logs/fsx-workload-%j.out
#SBATCH --error=/home/alice/logs/fsx-workload-%j.err

# The wrapper injects FSX_STATE_FILE into this job's environment.
# The workload script sources it to get FSX_ID, FSX_DNS, FSX_MOUNT_NAME, etc.
exec /opt/slurm/etc/workloads/jobs/scenario4/job2-run-workload.sh
