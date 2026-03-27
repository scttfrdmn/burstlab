#!/bin/bash
# =============================================================================
# teardown.sh — BurstLab clean shutdown
#
# Gracefully drains the cluster and terminates any burst nodes before
# running terraform destroy. This prevents orphaned EC2 instances and
# avoids Slurm error states on next deploy.
#
# Run from the TERRAFORM DIRECTORY (not on the head node):
#   cd terraform/generations/gen1-slurm2205-centos8/
#   bash ../../../scripts/teardown.sh
#
# Or pass the head node IP to drain first:
#   HEAD_NODE_IP=x.x.x.x bash scripts/teardown.sh
# =============================================================================

set -uo pipefail

HEAD_NODE_IP="${HEAD_NODE_IP:-}"
SBIN=/opt/slurm/bin

_info() { echo ">>> $1"; }
_warn() { echo "[WARN] $1"; }

# If we have SSH access to the head node, drain gracefully first
if [ -n "$HEAD_NODE_IP" ]; then
  _info "Draining cluster on $HEAD_NODE_IP before destroy..."
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "centos@$HEAD_NODE_IP" "
    set -e
    SBIN=/opt/slurm/bin

    # Cancel all running/pending jobs
    echo 'Cancelling all jobs...'
    \$SBIN/scancel --state=RUNNING --partition=cloud 2>/dev/null || true
    \$SBIN/scancel --state=PENDING 2>/dev/null || true

    # Force-suspend any remaining cloud nodes to terminate EC2 instances
    echo 'Suspending cloud nodes...'
    CLOUD_NODES=\$(\$SBIN/sinfo -p cloud -h -o '%N' 2>/dev/null)
    if [ -n \"\$CLOUD_NODES\" ]; then
      \$SBIN/scontrol update NodeName=\"\$CLOUD_NODES\" State=POWER_DOWN 2>/dev/null || true
    fi

    # Wait briefly for instances to start terminating
    sleep 10

    # Run suspend.py directly for any remaining cloud nodes (belt and suspenders)
    IDLE_CLOUD=\$(\$SBIN/sinfo -p cloud -h -o '%T %N' 2>/dev/null | grep -v CLOUD | awk '{print \$2}' | paste -sd,)
    if [ -n \"\$IDLE_CLOUD\" ]; then
      echo 'Running suspend.py for remaining cloud nodes...'
      /opt/slurm/etc/aws/suspend.py \"\$IDLE_CLOUD\" 2>/dev/null || true
    fi

    # Drain the controller
    echo 'Stopping Slurm services...'
    systemctl stop slurmctld 2>/dev/null || true
    systemctl stop slurmdbd 2>/dev/null || true
    systemctl stop munge 2>/dev/null || true

    echo 'Head node drained.'
  " && _info "Cluster drained successfully." || _warn "SSH drain failed — proceeding with terraform destroy anyway."
fi

# Check for any orphaned burst instances before destroying
_info "Checking for running burst instances..."
# This requires AWS CLI and assumes the profile is set
if command -v aws >/dev/null 2>&1; then
  BURST_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=burstlab" "Name=instance-state-name,Values=running,pending" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text \
    --profile "${AWS_PROFILE:-aws}" \
    --region "${AWS_DEFAULT_REGION:-us-west-2}" 2>/dev/null || echo "")

  if [ -n "$BURST_INSTANCES" ]; then
    _warn "Found running burst instances: $BURST_INSTANCES"
    echo "Terminating them before destroy..."
    aws ec2 terminate-instances \
      --instance-ids $BURST_INSTANCES \
      --profile "${AWS_PROFILE:-aws}" \
      --region "${AWS_DEFAULT_REGION:-us-west-2}" >/dev/null
    echo "Waiting for termination..."
    aws ec2 wait instance-terminated \
      --instance-ids $BURST_INSTANCES \
      --profile "${AWS_PROFILE:-aws}" \
      --region "${AWS_DEFAULT_REGION:-us-west-2}"
    echo "Burst instances terminated."
  else
    _info "No running burst instances found."
  fi
fi

# Run terraform destroy
if [ -f "terraform.tfvars" ] || [ -f "main.tf" ]; then
  _info "Running terraform destroy..."
  terraform destroy -auto-approve
  _info "Terraform destroy complete."
else
  echo
  echo "This script must be run from a Terraform generation directory, or"
  echo "set HEAD_NODE_IP and run it manually. Terraform destroy not run."
  echo
  echo "To destroy manually:"
  echo "  cd terraform/generations/gen1-slurm2205-centos8/"
  echo "  terraform destroy"
fi
