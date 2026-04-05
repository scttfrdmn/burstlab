#!/bin/bash
# =============================================================================
# scenario4/burst-buffer/example-job.sh — Example job for burst_buffer/lua
#
# Submit with standard sbatch:
#   sbatch example-job.sh
#
# The #BB directive is parsed at submit time. The burst buffer framework:
#   1. Validates the directive (slurm_bb_job_process)
#   2. Creates FSx during stage-in — job shows as BF in squeue (slurm_bb_data_in)
#   3. Injects FSX_STATE_FILE into job env (slurm_bb_pre_run)
#   4. Job runs normally
#   5. Flushes output to S3 (slurm_bb_post_run)
#   6. Destroys FSx (slurm_bb_data_out)
#
# Prerequisite: Slurm must be built with --with-lua and burstbuffer.conf must
# be deployed. See terraform/workloads/scenario4-burst-buffer/.
#
# SA talking point: "This is identical to how DataWarp jobs look on Cray XC
# or how GPFS Burst Buffer works on IBM Spectrum LSF. The #BB directive is
# an HPC industry standard. We're implementing it against FSx instead of
# on-prem hardware. Same operator experience, cloud-native backend."
# =============================================================================

#BB create_persistent name=myfsx capacity=1200GB access=striped type=scratch

#SBATCH --job-name=fsx-workload
#SBATCH --partition=aws
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --time=01:00:00
#SBATCH --output=/home/alice/logs/fsx-workload-%j.out
#SBATCH --error=/home/alice/logs/fsx-workload-%j.err

# FSX_STATE_FILE is injected by slurm_bb_pre_run via slurm.job_environment_set()
exec /opt/slurm/etc/workloads/jobs/scenario4/job2-run-workload.sh
