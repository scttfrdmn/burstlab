# =============================================================================
# slurmdbd.conf — BurstLab Gen 3
# Slurm 24.05.x / Rocky Linux 10
#
# No structural changes from Gen 1/2. slurmdbd.conf format is stable across
# Slurm 22.05, 23.11, and 24.05.
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

# --- Purge -------------------------------------------------------------------
PurgeEventAfter=1month
PurgeJobAfter=12months
PurgeResvAfter=1month
PurgeStepAfter=1month
PurgeSuspendAfter=1month
PurgeTXNAfter=12months
PurgeUsageAfter=24months
