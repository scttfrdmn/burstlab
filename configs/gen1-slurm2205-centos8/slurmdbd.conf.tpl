# =============================================================================
# slurmdbd.conf — Slurm Database Daemon configuration
# BurstLab Gen 1 — Slurm 22.05.11 / CentOS 8
#
# slurmdbd is the accounting daemon. Plugin v2 uses it to track node state
# history and enforce job accounting. Without it, SuspendTime-based power
# save does not work reliably.
#
# This file must be owned by slurm:slurm and mode 0600.
# =============================================================================

# --- Identity ----------------------------------------------------------------
DbdHost=headnode
DbdPort=6819
SlurmUser=slurm

# --- Storage -----------------------------------------------------------------
StorageType=accounting_storage/mysql
StorageHost=localhost
StoragePort=3306
StorageUser=slurm
StoragePass=${slurmdbd_db_password}
StorageLoc=slurm_acct_db

# --- Logging -----------------------------------------------------------------
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/var/run/slurmdbd.pid
DebugLevel=info

# --- Purge (keep history manageable for a demo cluster) ----------------------
PurgeEventAfter=1month
PurgeJobAfter=12months
PurgeResvAfter=1month
PurgeStepAfter=1month
PurgeSuspendAfter=1month
PurgeTXNAfter=12months
PurgeUsageAfter=24months
