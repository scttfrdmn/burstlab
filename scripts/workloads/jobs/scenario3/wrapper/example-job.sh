#!/bin/bash
# =============================================================================
# scenario3/wrapper/example-job.sh — Example workload for efs-sbatch wrapper
#
# Submit with:
#   efs-sbatch example-job.sh
#
# The #SBATCH --comment=efs line is the only addition required. The wrapper
# creates the EFS filesystem, injects EFS_STATE_FILE, and submits the job.
# =============================================================================

#SBATCH --job-name=efs-workload
#SBATCH --partition=aws
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --time=01:00:00
#SBATCH --comment=efs
#SBATCH --output=/home/alice/logs/efs-workload-%j.out
#SBATCH --error=/home/alice/logs/efs-workload-%j.err

exec /opt/slurm/etc/workloads/jobs/scenario3/job2-run-workload.sh
