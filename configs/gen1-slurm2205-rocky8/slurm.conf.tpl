# =============================================================================
# slurm.conf — BurstLab Gen 1
# Slurm 22.05.11 on CentOS 8 with AWS Plugin for Slurm v2
#
# This is a template. Variables in $${VAR} are substituted by Terraform/CDK
# at deploy time via templatefile(). The resulting file is written to
# /opt/slurm/etc/slurm.conf on every node via EFS.
#
# TCU context: This configuration mirrors what a corrected hpccw01/hpclogin
# config would look like — all nodes use the same file, directives are
# consistent, and the Plugin v2 power-save section is complete.
# =============================================================================

# --- Cluster Identity --------------------------------------------------------
ClusterName=${cluster_name}
SlurmctldHost=headnode(${head_node_ip})

# --- Slurm Daemon User -------------------------------------------------------
# SchedMD best practice: slurmctld drops privileges to SlurmUser after startup.
# This ensures only the slurm user (not root) runs the controller, and that
# change_state.py cron (run as slurm) has permission to call scontrol update.
SlurmUser=slurm

# --- Authentication ----------------------------------------------------------
# Munge is the standard shared-secret auth for on-prem Slurm clusters.
# All nodes share /etc/munge/munge.key (distributed via EFS at deploy time).
AuthType=auth/munge
CryptoType=crypto/munge
MpiDefault=none

# --- Process & Task Tracking -------------------------------------------------
# cgroup-based tracking is required for accurate resource accounting.
# Without it, jobs can consume more memory than requested.
ProctrackType=proctrack/cgroup
TaskPlugin=task/affinity,task/cgroup

# --- Scheduler ---------------------------------------------------------------
SchedulerType=sched/backfill
SelectType=select/cons_tres
# CR_Core_Memory: allocates by core AND memory. Prevents over-subscription.
# TCU had SelectType mismatched between nodes — this must be identical everywhere.
SelectTypeParameters=CR_Core_Memory

# --- Accounting --------------------------------------------------------------
# slurmdbd is required by Plugin v2 for node state tracking.
# Without it, the plugin cannot reliably detect burst node timeouts.
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
# These values are read by common.py and validated against config.json.
# They MUST match the values in /opt/slurm/etc/aws/config.json exactly.
#
# PrivateData=CLOUD: makes cloud nodes visible in sinfo even when powered down.
# Without this, 'sinfo' shows no cloud nodes and confuses users/SAs.
PrivateData=CLOUD

ResumeProgram=/opt/slurm/etc/aws/resume.py
SuspendProgram=/opt/slurm/etc/aws/suspend.py

# ResumeRate/SuspendRate: max nodes to resume/suspend per cycle (0 = unlimited).
# Set high (100) for demos so burst feels snappy.
ResumeRate=100
SuspendRate=100

# ResumeTimeout: seconds Slurm waits for a cloud node to become IDLE after
# resumption. AWS m7a.xlarge cold starts occasionally take 5-6 minutes (EFS
# mount, slurmd registration). 600s gives comfortable headroom; change_state.py
# auto-recovers any node that does hit the timeout.
# ResumeProgram is called. m7a instances typically register in 90-120s.
# 300s gives plenty of margin.
ResumeTimeout=600

# SuspendTime: seconds a node must be idle before SuspendProgram is called.
# Must be > ResumeTimeout to avoid terminate-then-immediately-resume loops.
# 650 = 600 (ResumeTimeout) + 50s buffer.
SuspendTime=650

# SuspendExcNodes: exclude static on-prem compute nodes from power-saving.
# Without this, SuspendProgram is called on all idle nodes including the static
# compute nodes — Slurm marks them POWERED_DOWN and they become unavailable.
SuspendExcNodes=compute[01-%{ if compute_node_count < 10 }0%{ endif }${compute_node_count}]

# TreeWidth: how many nodes slurmctld fans out to simultaneously for messaging.
# Set high for cloud environments — default (50) throttles burst signaling.
TreeWidth=60000

# ReturnToService=2: nodes automatically return from DOWN to IDLE when they
# re-register. Without this, a bounced burst node requires manual scontrol.
ReturnToService=2

# DebugFlags=NO_CONF_HASH: disables config file hash checking between nodes.
# Required for cloud nodes because they read slurm.conf from EFS after the
# controller started — hash mismatch would prevent slurmd from starting.
# TCU's hpclogin/hpccw01 divergence is exactly this problem.
DebugFlags=NO_CONF_HASH

# --- On-Prem Compute Nodes ---------------------------------------------------
# Static nodes — always present, never suspended.
# RealMemory: m7a.2xlarge has 32 GB total RAM. After kernel and OS overhead,
# the node reports ~31178 MB to slurmd. We configure 31000 MB (slightly less
# than the actual reported value) so slurmd's hardware check passes without
# draining the node for "Low RealMemory". Setting it too high causes
# INVALID_REG state.
NodeName=compute[01-%{ if compute_node_count < 10 }0%{ endif }${compute_node_count}] CPUs=8 RealMemory=31000 State=IDLE
PartitionName=local Nodes=compute[01-%{ if compute_node_count < 10 }0%{ endif }${compute_node_count}] Default=YES MaxTime=INFINITE State=UP

# --- AWS Burst Nodes ---------------------------------------------------------
# Generated by: python3 /opt/slurm/etc/aws/generate_conf.py
# Run once after partitions.json and config.json are in place, then append
# the output (slurm.conf.aws) below. This section documents what it produces:
#
#   NodeName=aws-burst-[0-7] CPUs=8 RealMemory=31000 Weight=1 State=CLOUD
#   PartitionName=aws Nodes=aws-burst-[0-7] MaxTime=4:00:00 State=UP
#
# The node names MUST match: {PartitionName}-{NodeGroupName}-{index}
# as defined in partitions.json. The EC2 Name tag is set to this value
# by resume.py, and the burst node reads it from IMDS to set SLURM_NODENAME.

${burst_node_conf}
