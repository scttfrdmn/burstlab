#!/bin/bash
# =============================================================================
# teardown.sh — BurstLab clean shutdown
#
# Gracefully drains the cluster, terminates burst nodes, then runs
# terraform destroy. Prevents orphaned EC2 instances (Plugin v2-launched
# burst nodes are NOT in Terraform state and must be cleaned up first).
#
# Usage (from the Terraform generation directory):
#   cd terraform/generations/gen1-slurm2205-rocky8/
#   AWS_PROFILE=aws HEAD_NODE_IP=x.x.x.x bash ../../../scripts/teardown.sh
#
# HEAD_NODE_IP is optional but strongly recommended — enables graceful Slurm
# drain before destroy. Without it, burst instances are still terminated via
# EC2 tag scan, but running jobs will be killed without notice.
#
# To skip terraform destroy (cleanup only):
#   SKIP_DESTROY=true AWS_PROFILE=aws bash scripts/teardown.sh
# =============================================================================

set -uo pipefail

HEAD_NODE_IP="${HEAD_NODE_IP:-}"
CLUSTER="${CLUSTER:-burstlab-gen1}"
REGION="${AWS_DEFAULT_REGION:-us-west-2}"
SKIP_DESTROY="${SKIP_DESTROY:-false}"
KEY="${KEY:-~/.ssh/burstlab-key.pem}"

# Require AWS_PROFILE
[ -n "${AWS_PROFILE:-}" ] || { echo "ERROR: AWS_PROFILE is not set. Use: AWS_PROFILE=aws bash $0"; exit 1; }

_info() { echo ">>> $1"; }
_warn() { echo "[WARN] $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Step 1: Graceful Slurm drain (if we can reach the head node)
# -----------------------------------------------------------------------------
if [ -n "$HEAD_NODE_IP" ]; then
  _info "Draining cluster on $HEAD_NODE_IP before destroy..."
  ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=15 "rocky@$HEAD_NODE_IP" "
    export SLURM_CONF=/opt/slurm/etc/slurm.conf
    SBIN=/opt/slurm/bin

    echo 'Cancelling all running and pending jobs...'
    \$SBIN/scancel --state=RUNNING 2>/dev/null || true
    \$SBIN/scancel --state=PENDING 2>/dev/null || true
    sleep 2

    echo 'Triggering power-down on all burst nodes...'
    # Get all burst partitions (everything except 'local')
    BURST_PARTITIONS=\$(\$SBIN/sinfo -h -o '%R' 2>/dev/null | grep -v '^local$' | sort -u | tr '\n' ',')
    BURST_PARTITIONS=\${BURST_PARTITIONS%,}
    if [ -n \"\$BURST_PARTITIONS\" ]; then
      BURST_NODES=\$(\$SBIN/sinfo -p \"\$BURST_PARTITIONS\" -h -o '%N' 2>/dev/null | tr '\n' ',' | sed 's/,\$//')
      if [ -n \"\$BURST_NODES\" ]; then
        echo \"  Burst partitions: \$BURST_PARTITIONS\"
        echo \"  Burst nodes:      \$BURST_NODES\"
        sudo SLURM_CONF=\$SLURM_CONF \$SBIN/scontrol update NodeName=\"\$BURST_NODES\" State=POWER_DOWN 2>/dev/null || true
      fi
    fi
    sleep 5

    echo 'Stopping Slurm services...'
    sudo systemctl stop slurmctld 2>/dev/null || true
    sudo systemctl stop slurmdbd  2>/dev/null || true
    sudo systemctl stop munge     2>/dev/null || true

    echo 'Head node drained.'
  " && _info "Cluster drained." || _warn "SSH drain failed — will force-terminate via EC2 API."
fi

# -----------------------------------------------------------------------------
# Step 2: Terminate any burst EC2 instances (includes zombies from prior runs)
# -----------------------------------------------------------------------------
_info "Cleaning up burst EC2 instances..."
AWS_PROFILE=$AWS_PROFILE CLUSTER=$CLUSTER AWS_DEFAULT_REGION=$REGION \
  bash "$SCRIPT_DIR/cleanup-burst-nodes.sh" --cluster "$CLUSTER" --region "$REGION"

# -----------------------------------------------------------------------------
# Step 3: Terraform destroy
# -----------------------------------------------------------------------------
if [ "$SKIP_DESTROY" = true ]; then
  _info "SKIP_DESTROY=true — skipping terraform destroy."
  exit 0
fi

if [ -f "terraform.tfvars" ] || [ -f "main.tf" ]; then
  _info "Running terraform destroy..."
  AWS_PROFILE=$AWS_PROFILE terraform destroy -auto-approve
  _info "Terraform destroy complete."
else
  _warn "Not in a Terraform directory — skipping terraform destroy."
  echo "  Run manually: cd terraform/generations/gen1-slurm2205-rocky8/ && AWS_PROFILE=aws terraform destroy"
fi
