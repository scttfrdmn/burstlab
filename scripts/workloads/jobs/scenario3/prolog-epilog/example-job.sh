#!/bin/bash
# =============================================================================
# scenario3/prolog-epilog/example-job.sh — Example job for prolog/epilog approach
#
# Submit with:
#   sbatch --partition=aws example-job.sh
#
# The SlurmctldProlog sees #SBATCH --comment=efs, creates the EFS filesystem
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

exec /opt/slurm/etc/workloads/jobs/scenario3/job2-run-workload.sh
