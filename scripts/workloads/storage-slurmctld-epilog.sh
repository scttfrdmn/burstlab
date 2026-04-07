#!/bin/bash
# =============================================================================
# storage-slurmctld-epilog.sh — Combined EpilogSlurmctld for FSx and EFS
#
# Deployed to /opt/slurm/etc/scripts/storage-slurmctld-epilog.sh
# Referenced in slurm.conf:
#   EpilogSlurmctld=/opt/slurm/etc/scripts/storage-slurmctld-epilog.sh
# =============================================================================

set -euo pipefail

COMMENT="${SLURM_JOB_COMMENT:-}"

case "$COMMENT" in
  fsx:*)
    exec /opt/slurm/etc/scripts/fsx-slurmctld-epilog.sh
    ;;
  efs)
    exec /opt/slurm/etc/scripts/efs-slurmctld-epilog.sh
    ;;
  *)
    exit 0
    ;;
esac
