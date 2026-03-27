#!/bin/bash
# =============================================================================
# demo-burst.sh — BurstLab cloud bursting demonstration
#
# Run this on the head node to demonstrate the full burst cycle:
#   1. Submit a local job (runs on static compute nodes)
#   2. Submit a cloud job (triggers Plugin v2 → EC2 CreateFleet)
#   3. Watch the burst node lifecycle: CLOUD* → ALLOCATED → RUNNING → IDLE → POWER_DOWN
#
# This is designed to be run live during an SA demo or customer walkthrough.
# Every step is narrated so the audience understands what's happening.
#
# Usage: bash /opt/slurm/etc/demo-burst.sh
# =============================================================================

set -uo pipefail
SBIN=/opt/slurm/bin

_banner() {
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  $1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

_step() { echo; echo ">>> $1"; }
_info() { echo "    $1"; }
_wait() { echo; read -r -p "    [Press Enter to continue] " _; }

# -----------------------------------------------------------------------------
_banner "BurstLab Gen 1 — Cloud Bursting Demo"
# -----------------------------------------------------------------------------

echo
echo "This demo shows Slurm cloud bursting via AWS Plugin v2."
echo "The cluster has:"
echo "  - local partition:  static compute nodes (on-prem simulation)"
echo "  - cloud partition:  burst nodes launched on-demand via EC2 Fleet"
echo

# Show initial cluster state
_step "Current cluster state (sinfo)"
$SBIN/sinfo
echo
echo "Note: cloud nodes show CLOUD* — they are powered off but registered."
echo "The * means PrivateData=CLOUD is set, making them visible in sinfo."

_wait

# -----------------------------------------------------------------------------
_banner "Part 1: Local Job (On-Prem Compute)"
# -----------------------------------------------------------------------------

_step "Submitting a job to the local (on-prem) partition"
_info "This job will run on a static compute node that is already running."

LOCAL_JOB_ID=$($SBIN/sbatch \
  --partition=local \
  --job-name=demo-local \
  --output=/tmp/demo-local-%j.out \
  --wrap="echo 'Job running on:' && hostname && echo 'CPUs:' && nproc && sleep 15" \
  | awk '{print $NF}')

echo "    Submitted job $LOCAL_JOB_ID to local partition"

_step "Watching queue..."
for i in $(seq 1 6); do
  sleep 3
  echo "--- squeue at T+${i}0s ---"
  $SBIN/squeue --format="%-8i %-12j %-10P %-8T %-6D %-12l %-12N" 2>/dev/null || true
done

_step "Job output:"
cat /tmp/demo-local-${LOCAL_JOB_ID}.out 2>/dev/null || echo "(job may still be running)"

_wait

# -----------------------------------------------------------------------------
_banner "Part 2: Cloud Burst Job"
# -----------------------------------------------------------------------------

_step "Pre-burst cluster state"
$SBIN/sinfo --format="%-12P %-6a %-10T %-6D %-14C %-N"
echo
echo "cloud-burst nodes are in CLOUD* state — EC2 instances do NOT exist yet."
echo "When we submit to the cloud partition, slurmctld will call resume.py,"
echo "which calls ec2:CreateFleet to launch an m7a.xlarge in the cloud subnet."

_wait

_step "Submitting a job to the cloud partition"
_info "This triggers Plugin v2 resume.py → EC2 CreateFleet → m7a.xlarge launch."

BURST_JOB_ID=$($SBIN/sbatch \
  --partition=cloud \
  --job-name=demo-burst \
  --output=/tmp/demo-burst-%j.out \
  --wrap="echo 'Burst node hostname:' && hostname && echo 'Instance ID:' && curl -sf -H 'X-aws-ec2-metadata-token: \$(curl -sX PUT http://169.254.169.254/latest/api/token -H X-aws-ec2-metadata-token-ttl-seconds:60)' http://169.254.169.254/latest/meta-data/instance-id && echo 'AZ:' && curl -sf -H 'X-aws-ec2-metadata-token: \$(curl -sX PUT http://169.254.169.254/latest/api/token -H X-aws-ec2-metadata-token-ttl-seconds:60)' http://169.254.169.254/latest/meta-data/placement/availability-zone && sleep 60" \
  | awk '{print $NF}')

echo "    Submitted job $BURST_JOB_ID to cloud partition"

_step "Watching burst lifecycle (this takes 2-3 minutes)..."
echo "State transitions to watch:"
echo "  CLOUD*    → node is powered off, resume.py has been called"
echo "  ALLOCATED → node is launching, waiting for slurmd to register"
echo "  RUNNING   → job is executing on the burst node"
echo "  IDLE      → job done, node idle (will power down after SuspendTime=350s)"
echo "  POWER_DOWN→ SuspendProgram called, EC2 instance terminated"
echo

LAST_STATE=""
for i in $(seq 1 40); do
  sleep 15
  ELAPSED=$((i * 15))
  CURRENT_STATE=$($SBIN/sinfo -p cloud -h -o "%T" 2>/dev/null | head -1 | tr -d ' ')

  if [ "$CURRENT_STATE" != "$LAST_STATE" ]; then
    echo "T+${ELAPSED}s: Cloud node state changed: $LAST_STATE → $CURRENT_STATE"
    LAST_STATE="$CURRENT_STATE"
  else
    echo "T+${ELAPSED}s: Cloud node state: $CURRENT_STATE"
  fi

  # Show the queue
  $SBIN/squeue --format="%-8i %-12j %-10P %-8T %-6D %-12l %-12N" 2>/dev/null | grep -v "^$" || true

  # Exit loop if job completed
  JOB_STATE=$($SBIN/squeue -j "$BURST_JOB_ID" -h -o "%T" 2>/dev/null || echo "DONE")
  if [ "$JOB_STATE" = "DONE" ] || [ -z "$JOB_STATE" ]; then
    echo
    echo "Job $BURST_JOB_ID completed."
    break
  fi
done

_step "Burst job output:"
cat /tmp/demo-burst-${BURST_JOB_ID}.out 2>/dev/null || echo "(output not yet available)"

# Show AWS Plugin log
_step "Plugin v2 log (last 20 lines):"
tail -20 /var/log/slurm/aws_plugin.log 2>/dev/null || echo "(log not found)"

_wait

# -----------------------------------------------------------------------------
_banner "Part 3: What Just Happened"
# -----------------------------------------------------------------------------

echo
echo "What Plugin v2 did when the cloud job was submitted:"
echo
echo "  1. slurmctld detected job pending with nodes in CLOUD* state"
echo "  2. slurmctld called ResumeProgram (/opt/slurm/etc/aws/resume.py)"
echo "  3. resume.py read partitions.json → called ec2:CreateFleet"
echo "     - Fleet type: instant (not maintain)"
echo "     - Instance: m7a.xlarge in cloud subnets A or B"
echo "     - Named the EC2 instance: cloud-burst-0 (EC2 Name tag)"
echo "  4. EC2 instance launched, ran burst-node-init.sh:"
echo "     - Read its name from IMDS tag (InstanceMetadataTags=enabled)"
echo "     - Mounted EFS (/home and /opt/slurm)"
echo "     - Copied munge key from EFS"
echo "     - Started slurmd -N cloud-burst-0"
echo "  5. slurmd registered with slurmctld as 'cloud-burst-0'"
echo "  6. slurmctld dispatched the job to cloud-burst-0"
echo "  7. Job ran, printed hostname = cloud-burst-0"
echo "  8. After SuspendTime (350s idle), SuspendProgram was called"
echo "  9. suspend.py found the EC2 instance by Name tag and terminated it"
echo
echo "Key files to examine:"
echo "  /opt/slurm/etc/aws/partitions.json  — fleet configuration"
echo "  /opt/slurm/etc/aws/config.json      — plugin settings"
echo "  /opt/slurm/etc/slurm.conf           — power save directives"
echo "  /var/log/slurm/aws_plugin.log       — plugin execution log"
echo "  /var/log/slurm/slurmctld.log        — controller log"
echo
echo "To watch the node power down:"
echo "  watch -n 10 'sinfo && echo && squeue'"

_banner "Demo Complete"
