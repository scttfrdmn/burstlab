#!/bin/bash
# =============================================================================
# teardown.sh — BurstLab clean shutdown
#
# Gracefully drains the cluster, terminates burst nodes, then runs
# terraform destroy. Prevents orphaned EC2 instances (Plugin v2-launched
# burst nodes are NOT in Terraform state and must be cleaned up first).
#
# Usage (from the Terraform generation directory, any generation):
#   cd terraform/generations/<gen>/
#   AWS_PROFILE=aws bash ../../../scripts/teardown.sh
#
# Cluster name, region, SSH user (rocky / ubuntu / ec2-user) and head node IP are
# read from `terraform output` in that directory; override with CLUSTER, AWS_REGION,
# SSH_USER, HEAD_NODE_IP. The head node IP enables a graceful Slurm drain before
# destroy. Without it, burst instances are still terminated via EC2 tag scan, but
# running jobs will be killed without notice.
#
# To skip terraform destroy (cleanup only):
#   SKIP_DESTROY=true AWS_PROFILE=aws bash scripts/teardown.sh
# =============================================================================

set -uo pipefail

SKIP_DESTROY="${SKIP_DESTROY:-false}"
KEY="${KEY:-~/.ssh/burstlab-key.pem}"

# Read a value from `terraform output` when run from a generation directory.
_tf_out() { [ -f main.tf ] && command -v terraform >/dev/null 2>&1 && terraform output -raw "$1" 2>/dev/null; }

# Resolve cluster identity: env wins, then terraform output. No guessed defaults —
# a wrong cluster/region would make the burst-node scan find nothing and "succeed".
HEAD_NODE_IP="${HEAD_NODE_IP:-$(_tf_out head_node_public_ip)}"
CLUSTER="${CLUSTER:-$(_tf_out cluster_name)}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(_tf_out aws_region)}}"
SSH_USER="${SSH_USER:-$(_tf_out ssh_user)}"
[ -n "$CLUSTER" ] || { echo "ERROR: cluster name unknown. Run from a generation directory or set CLUSTER=<name>."; exit 1; }
[ -n "$REGION" ]  || { echo "ERROR: region unknown. Run from a generation directory or set AWS_REGION."; exit 1; }

# Require AWS_PROFILE
[ -n "${AWS_PROFILE:-}" ] || { echo "ERROR: AWS_PROFILE is not set. Use: AWS_PROFILE=aws bash $0"; exit 1; }

_info() { echo ">>> $1"; }
_warn() { echo "[WARN] $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------------------
# Step 1: Graceful Slurm drain (if we can reach the head node)
# -----------------------------------------------------------------------------
if [ -n "$HEAD_NODE_IP" ] && [ -z "$SSH_USER" ]; then
  _warn "SSH_USER unknown (rocky / ubuntu / ec2-user) — skipping graceful drain. Set SSH_USER to enable it."
  HEAD_NODE_IP=""
fi
if [ -n "$HEAD_NODE_IP" ]; then
  _info "Draining cluster on $HEAD_NODE_IP before destroy..."
  ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=15 "$SSH_USER@$HEAD_NODE_IP" "
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
# Cluster/region are passed as flags (they override the script's env defaults),
# so only AWS_PROFILE needs to be exported into the child's environment.
AWS_PROFILE="$AWS_PROFILE" \
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
  echo "  Run manually: cd terraform/generations/<gen>/ && AWS_PROFILE=aws terraform destroy"
fi
