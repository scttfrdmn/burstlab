# =============================================================================
# slurm.conf — BurstLab Gen 6
# Slurm 25.11.x on Amazon Linux 2023 with AWS Plugin for Slurm v2
#
# This is a template. Variables in $${VAR} are substituted by Terraform
# at deploy time via templatefile(). Written to /opt/slurm/etc/slurm.conf
# on every node via EFS.
#
# Gen 6 notes (Slurm 25.11 on AL2023):
#   - NO cloud_reg_addrs. Slurm 25.11 makes that SlurmctldParameters option a hard
#     error ("defunct"). It was never a documented option (absent from slurm.conf.5
#     through 24.05) and was always redundant here: the AWS plugin's resume.py pushes
#     each burst node's address in explicitly via `scontrol update nodename=<n>
#     nodeaddr=<ip> nodehostname=<h>` once the EC2 instance has an IP. That is exactly
#     the default cloud-node registration path Slurm documents (see `cloud_dns`), so
#     dropping the parameter changes nothing operationally — the plugin still sets the
#     address. (Gen 3/5 dropped it as well; 24.05 only warned, 25.11 rejects it.)
#   - TaskPlugin=task/cgroup: AL2023 uses cgroup v2 exclusively;
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
# AL2023 uses cgroup v2 only. task/cgroup in Slurm 25.11 uses the cgroup/v2
# plugin configured in cgroup.conf. task/affinity removed — redundant with cgroup.
TaskPlugin=task/cgroup

# --- Scheduler ---------------------------------------------------------------
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
# DefMemPerCPU: with memory consumable (CR_Core_Memory), a job that doesn't pass
# --mem / --mem-per-cpu is otherwise allocated ALL of the node's RealMemory, so
# `sbatch -c 1` occupies a whole node — and on the aws partition every such job
# launches its own EC2 instance. 3875 = RealMemory 31000 / CPUs 8, so a node's
# full core count fits exactly. Keep in sync with the NodeName / partitions.json
# CPUs and RealMemory if you change instance types. Jobs can still override with --mem.
DefMemPerCPU=3875

# --- Controller Parameters ---------------------------------------------------
# idle_on_node_suspend: powered-down cloud nodes show as IDLE (not IDLE~) in sinfo.
#   (Still valid in Slurm 25.11.)
# NOTE: cloud_reg_addrs is intentionally absent — it is defunct in Slurm 25.11 and
#   redundant with the AWS plugin (resume.py pushes NodeAddr in). See header.
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
