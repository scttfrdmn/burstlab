# =============================================================================
# slurm.conf — BurstLab Gen 3
# Slurm 24.05.x on Rocky Linux 10 with AWS Plugin for Slurm v2
#
# This is a template. Variables in $${VAR} are substituted by Terraform
# at deploy time via templatefile(). Written to /opt/slurm/etc/slurm.conf
# on every node via EFS.
#
# Gen 3 additions vs Gen 2 (23.11/Rocky 9):
#   - cloud_reg_addrs: burst nodes register with their actual EC2 IP address.
#     slurmctld accepts any address from a CLOUD node without pre-configuration.
#     This eliminates the "SLURM_NODENAME must match configured NodeAddr" failure
#     mode when EC2 assigns a different private IP than expected.
#   - TaskPlugin=task/cgroup: Rocky 10 uses cgroup v2 exclusively;
#     task/affinity is removed (deprecated in 24.x for pure-cgroup configs).
#   - cgroup.conf uses CgroupPlugin=cgroup/v2 (see separate file).
# =============================================================================

# --- Cluster Identity --------------------------------------------------------
ClusterName=${cluster_name}
SlurmctldHost=headnode(${head_node_ip})

# --- Slurm Daemon User -------------------------------------------------------
SlurmUser=slurm

# --- Authentication ----------------------------------------------------------
AuthType=auth/munge
CryptoType=crypto/munge
MpiDefault=none

# --- Process & Task Tracking -------------------------------------------------
ProctrackType=proctrack/cgroup
# Rocky 10 uses cgroup v2 only. task/cgroup in Slurm 24.05 uses the cgroup/v2
# plugin configured in cgroup.conf. task/affinity removed — redundant with cgroup.
TaskPlugin=task/cgroup

# --- Scheduler ---------------------------------------------------------------
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

# --- Controller Parameters ---------------------------------------------------
# idle_on_node_suspend: powered-down cloud nodes show as IDLE (not IDLE~) in sinfo.
# cloud_reg_addrs: cloud nodes register with their actual EC2 IP. slurmctld
#   records the address at registration time and uses it for subsequent comms.
#   This is the key Gen 3 improvement: burst nodes no longer need NodeAddr
#   pre-configured or matching a specific IP.
SlurmctldParameters=idle_on_node_suspend,cloud_reg_addrs

# --- Accounting --------------------------------------------------------------
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=headnode
AccountingStoragePort=6819
AccountingStorageEnforce=associations,limits

# --- Logging -----------------------------------------------------------------
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldDebug=info
SlurmdDebug=info
SlurmctldPidFile=/var/run/slurmctld.pid
SlurmdPidFile=/var/run/slurmd.pid

# --- State & Spool -----------------------------------------------------------
StateSaveLocation=/var/spool/slurm/ctld
SlurmdSpoolDir=/var/spool/slurm/d

# --- Timeouts ----------------------------------------------------------------
SlurmctldTimeout=120
SlurmdTimeout=300
InactiveLimit=0
MinJobAge=300
KillWait=30
Waittime=0

# --- Power Save / Cloud Bursting (Plugin v2) ---------------------------------
PrivateData=CLOUD

ResumeProgram=/opt/slurm/etc/aws/resume.py
SuspendProgram=/opt/slurm/etc/aws/suspend.py

ResumeRate=100
SuspendRate=100
ResumeTimeout=600
SuspendTime=650

SuspendExcNodes=compute[01-%{ if compute_node_count < 10 }0%{ endif }${compute_node_count}]

TreeWidth=60000
ReturnToService=2
DebugFlags=NO_CONF_HASH

# --- On-Prem Compute Nodes ---------------------------------------------------
NodeName=compute[01-%{ if compute_node_count < 10 }0%{ endif }${compute_node_count}] CPUs=8 RealMemory=31000 State=IDLE
PartitionName=local Nodes=compute[01-%{ if compute_node_count < 10 }0%{ endif }${compute_node_count}] Default=YES MaxTime=INFINITE State=UP

# --- AWS Burst Nodes ---------------------------------------------------------
# Generated at runtime by generate_conf.py → slurm.conf.aws, then appended here.

${burst_node_conf}
