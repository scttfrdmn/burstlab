#!/bin/bash
# =============================================================================
# storage-slurmctld-prolog.sh — Combined PrologSlurmctld for FSx and EFS
#
# Deployed to /opt/slurm/etc/scripts/storage-slurmctld-prolog.sh
# Referenced in slurm.conf:
#   PrologSlurmctld=/opt/slurm/etc/scripts/storage-slurmctld-prolog.sh
#   PrologEpilogTimeout=1800
#
# Dispatches based on #SBATCH --comment value:
#   --comment=fsx:<GB>   → create FSx SCRATCH_2 of <GB> gigabytes
#   --comment=efs        → create ephemeral EFS filesystem
#   (anything else)      → exit 0 immediately (no-op for all other jobs)
#
# This single script handles both storage types so only one PrologSlurmctld
# line is needed in slurm.conf.
# =============================================================================

set -euo pipefail

COMMENT="${SLURM_JOB_COMMENT:-}"

case "$COMMENT" in
  fsx:*)
    exec /opt/slurm/etc/scripts/fsx-slurmctld-prolog.sh
    ;;
  efs)
    exec /opt/slurm/etc/scripts/efs-slurmctld-prolog.sh
    ;;
  *)
    exit 0
    ;;
esac
