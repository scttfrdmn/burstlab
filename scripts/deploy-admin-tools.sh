#!/bin/bash
# =============================================================================
# deploy-admin-tools.sh — Deploy admin scripts to the head node after deploy
#
# Admin scripts (manage-partitions.sh) are too large to embed in EC2 UserData
# (16 KB limit). This script deploys them via SCP after terraform apply.
#
# Usage:
#   cd terraform/generations/gen1-slurm2205-rocky8/
#   HEAD_NODE_IP=$(AWS_PROFILE=aws terraform output -raw head_node_public_ip)
#   bash ../../../scripts/deploy-admin-tools.sh $HEAD_NODE_IP [path/to/key.pem]
#
# Or: HEAD_NODE_IP=x.x.x.x KEY=~/.ssh/burstlab-key.pem bash scripts/deploy-admin-tools.sh
# =============================================================================

set -uo pipefail

HEAD_NODE_IP="${1:-${HEAD_NODE_IP:-}}"
KEY="${2:-${KEY:-~/.ssh/burstlab-key.pem}}"

[ -n "$HEAD_NODE_IP" ] || { echo "Usage: $0 <head_node_ip> [key.pem]"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_OPTS="-i $KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15"

_info() { echo ">>> $1"; }

# Wait for SSH to be available (cloud-init may still be running)
_info "Waiting for SSH on $HEAD_NODE_IP..."
for attempt in $(seq 1 20); do
  ssh $SSH_OPTS rocky@$HEAD_NODE_IP "echo ok" >/dev/null 2>&1 && break
  echo "  attempt $attempt/20 — not ready yet, waiting 15s..."
  sleep 15
done
ssh $SSH_OPTS rocky@$HEAD_NODE_IP "echo ok" >/dev/null 2>&1 || { echo "ERROR: SSH never became available"; exit 1; }

# Wait for cloud-init to complete
_info "Waiting for cloud-init to complete..."
ssh $SSH_OPTS rocky@$HEAD_NODE_IP "
  for i in \$(seq 1 30); do
    grep -q 'init complete' /var/log/burstlab-init.log 2>/dev/null && exit 0
    sleep 10
  done
  exit 1
" || _info "[WARN] cloud-init may not be done — proceeding anyway."

# Deploy admin scripts
SCRIPTS=(manage-partitions.sh cleanup-burst-nodes.sh)

for script in "${SCRIPTS[@]}"; do
  if [ -f "$SCRIPT_DIR/$script" ]; then
    _info "Deploying $script..."
    scp $SSH_OPTS "$SCRIPT_DIR/$script" "rocky@$HEAD_NODE_IP:/tmp/$script"
    ssh $SSH_OPTS rocky@$HEAD_NODE_IP "sudo cp /tmp/$script /opt/slurm/etc/$script && sudo chmod 755 /opt/slurm/etc/$script"
    echo "  Installed at /opt/slurm/etc/$script"
  else
    echo "  [SKIP] $script not found in $SCRIPT_DIR"
  fi
done

_info "Admin tools deployed. Test with:"
echo "  ssh -i $KEY rocky@$HEAD_NODE_IP 'sudo /opt/slurm/etc/manage-partitions.sh list'"
