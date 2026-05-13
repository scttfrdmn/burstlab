# =============================================================================
# slurm.conf — BurstLab Gen 2
# Slurm 23.11.x on Rocky Linux 9 with AWS Plugin for Slurm v2
#
# This is a template. Variables in $${VAR} are substituted by Terraform
# at deploy time via templatefile(). Written to /opt/slurm/etc/slurm.conf
# on every node via EFS.
#
# Gen 2 additions vs Gen 1 (22.05/Rocky 8):
#   - SlurmctldParameters=idle_on_node_suspend: powered-down cloud nodes
#     appear as IDLE (not IDLE~) in sinfo — cleaner for demos and users
#   - TaskPlugin simplified to task/cgroup (affinity still works but cgroup
#     alone is sufficient for resource enforcement in 23.11+)
#   - slurmrestd available in this Slurm build (start manually for demos)
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
TaskPlugin=task/cgroup

# --- Scheduler ---------------------------------------------------------------
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

# --- Controller Parameters ---------------------------------------------------
# idle_on_node_suspend: Gen 2 addition. Powered-down cloud nodes report IDLE
# instead of IDLE~ in sinfo. Makes "sinfo" output cleaner for demos.
# Without it, users see "idle~" and ask "what does the ~ mean?" every time.
SlurmctldParameters=idle_on_node_suspend

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

# ResumeTimeout: seconds slurmctld waits for a cloud node to register after
# resume. m7a instances typically register in 60-120s. 600s gives comfortable
# headroom for cold starts and EFS mount retry loops.
ResumeTimeout=600

# SuspendTime: seconds a node must be idle before SuspendProgram is called.
# Must be > ResumeTimeout to avoid terminate-then-immediately-resume loops.
SuspendTime=650

# SuspendExcNodes: prevent on-prem compute nodes from being power-saved.
SuspendExcNodes=compute[01-%{ if compute_node_count < 10 }0%{ endif }${compute_node_count}]

TreeWidth=60000

# ReturnToService=2: nodes automatically return to IDLE when they re-register.
ReturnToService=2

# DebugFlags=NO_CONF_HASH: disables config hash checking between nodes.
# Required for cloud nodes that mount slurm.conf from EFS after controller start.
DebugFlags=NO_CONF_HASH

# --- On-Prem Compute Nodes ---------------------------------------------------
# m7a.2xlarge: 8 vCPU / 32 GB. RealMemory=31000 MB (slightly below reported
# ~31178 MB) prevents INVALID_REG drain from "Low RealMemory" check.
NodeName=compute[01-%{ if compute_node_count < 10 }0%{ endif }${compute_node_count}] CPUs=8 RealMemory=31000 State=IDLE
PartitionName=local Nodes=compute[01-%{ if compute_node_count < 10 }0%{ endif }${compute_node_count}] Default=YES MaxTime=INFINITE State=UP

# --- AWS Burst Nodes ---------------------------------------------------------
# Generated at runtime by generate_conf.py → slurm.conf.aws, then appended here.
# Node names follow: {PartitionName}-{NodeGroupName}-{index} (e.g., aws-burst-0)

${burst_node_conf}
