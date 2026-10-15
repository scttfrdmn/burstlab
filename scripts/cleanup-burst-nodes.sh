#!/bin/bash
# =============================================================================
# cleanup-burst-nodes.sh — Terminate orphaned BurstLab burst EC2 instances
#
# Burst nodes are launched by Plugin v2 (resume.py via ec2:CreateFleet) and
# are NOT tracked in Terraform state. If the cluster is destroyed (or if nodes
# fail to terminate normally), these instances become zombies — still running
# but with no slurmctld to report to. They run up cost and fill conntrack tables.
#
# This script finds burst nodes by their EC2 Name tag pattern (*-burst-*) and
# the burstlab Cluster tag, then terminates them. It is safe to run:
#   - Before terraform destroy  (called by teardown.sh)
#   - After terraform destroy   (cleanup of missed nodes)
#   - Any time nodes are stuck  (e.g., failed demo runs)
#
# Usage (from a generation directory, any other directory, or the head node):
#   AWS_PROFILE=aws bash scripts/cleanup-burst-nodes.sh [--cluster NAME] [--region REGION] [--dry-run]
#
# Options:
#   --cluster NAME    Cluster name (Cluster tag). Default: `terraform output cluster_name`
#                     in a generation directory, else the Cluster tag in
#                     /opt/slurm/etc/aws/partitions.json on the head node.
#   --region REGION   AWS region. Default: $AWS_REGION, $AWS_DEFAULT_REGION, then the
#                     same terraform-output / partitions.json lookup.
#   --dry-run         Show what would be terminated without doing it
#
# If HEAD_NODE_IP is set, also resets down/failed burst nodes in Slurm
# (SSH_USER defaults to `terraform output ssh_user`: rocky / ubuntu / ec2-user):
#   HEAD_NODE_IP=x.x.x.x AWS_PROFILE=aws bash scripts/cleanup-burst-nodes.sh
# =============================================================================

set -uo pipefail

CLUSTER="${CLUSTER:-}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
DRY_RUN=false
HEAD_NODE_IP="${HEAD_NODE_IP:-}"
SSH_USER="${SSH_USER:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --cluster)  CLUSTER="$2"; shift ;;
    --region)   REGION="$2"; shift ;;
    --dry-run)  DRY_RUN=true ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

_info() { echo ">>> $1"; }
_warn() { echo "[WARN] $1"; }

# Read a value from `terraform output` when run from a generation directory.
_tf_out() { [ -f main.tf ] && command -v terraform >/dev/null 2>&1 && terraform output -raw "$1" 2>/dev/null; }
# Read the Cluster tag / Region from the plugin config when run on the head node.
_plugin_cfg() {
  [ -f /opt/slurm/etc/aws/partitions.json ] && python3 -c "
import json, sys
ng = json.load(open('/opt/slurm/etc/aws/partitions.json'))['Partitions'][0]['NodeGroups'][0]
print(ng['Region'] if sys.argv[1] == 'region' else
      next(t['Value'] for t in ng.get('Tags', []) if t['Key'] == 'Cluster'))
" "$1" 2>/dev/null
}

# Resolve cluster identity: flags/env win, then terraform output, then plugin config.
# Never fall back to a guessed default — scanning the wrong cluster or region would
# report "no instances" and look like success.
: "${CLUSTER:=$(_tf_out cluster_name)}"
: "${CLUSTER:=$(_plugin_cfg cluster)}"
: "${REGION:=$(_tf_out aws_region)}"
: "${REGION:=$(_plugin_cfg region)}"
: "${SSH_USER:=$(_tf_out ssh_user)}"
[ -n "$CLUSTER" ] || { echo "ERROR: cluster name unknown. Run from a generation directory or pass --cluster NAME." >&2; exit 1; }
[ -n "$REGION" ]  || { echo "ERROR: region unknown. Set AWS_REGION or pass --region REGION." >&2; exit 1; }

# Require AWS CLI
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found"; exit 1; }

# Require AWS_PROFILE
[ -n "${AWS_PROFILE:-}" ] || { echo "ERROR: AWS_PROFILE is not set. Use: AWS_PROFILE=aws bash $0"; exit 1; }

_info "Scanning for burst instances (cluster=$CLUSTER, region=$REGION)..."

# Find burst instances by:
#   - Name tag matching *-burst-* (plugin v2 naming: {partition}-{nodegroup}-{N})
#   - Cluster tag matching the cluster name
#   - Not terminated/stopped
BURST_INSTANCES=$(AWS_PROFILE=$AWS_PROFILE aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:Name,Values=*-burst-*" \
    "Name=tag:Cluster,Values=$CLUSTER" \
    "Name=instance-state-name,Values=running,pending,stopping" \
  --query "Reservations[].Instances[].{ID:InstanceId,Name:Tags[?Key=='Name']|[0].Value,State:State.Name}" \
  --output text 2>/dev/null)

if [ -z "$BURST_INSTANCES" ]; then
  _info "No burst instances found for cluster '$CLUSTER'."
else
  echo "Burst instances found:"
  echo "$BURST_INSTANCES" | awk '{printf "  %-24s  %-20s  %s\n", $1, $2, $3}'
  echo

  INSTANCE_IDS=$(echo "$BURST_INSTANCES" | awk '{print $1}' | tr '\n' ' ')

  if [ "$DRY_RUN" = true ]; then
    _warn "[DRY RUN] Would terminate: $INSTANCE_IDS"
  else
    _info "Terminating ${#INSTANCE_IDS} instance(s)..."
    AWS_PROFILE=$AWS_PROFILE aws ec2 terminate-instances \
      --region "$REGION" \
      --instance-ids $INSTANCE_IDS \
      --query "TerminatingInstances[].{ID:InstanceId,State:CurrentState.Name}" \
      --output table

    _info "Waiting for termination..."
    AWS_PROFILE=$AWS_PROFILE aws ec2 wait instance-terminated \
      --region "$REGION" \
      --instance-ids $INSTANCE_IDS
    _info "All burst instances terminated."
  fi
fi

# If we have access to the head node, also reset any down/failed burst nodes in Slurm
if [ -n "$HEAD_NODE_IP" ]; then
  KEY="${KEY:-~/.ssh/burstlab-key.pem}"
  [ -n "$SSH_USER" ] || { echo "ERROR: SSH_USER unknown (rocky / ubuntu / ec2-user). Set SSH_USER or run from a generation directory." >&2; exit 1; }
  _info "Resetting failed/down burst nodes in Slurm on $HEAD_NODE_IP..."
  ssh -i "$KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$HEAD_NODE_IP" "
    SLURM_CONF=/opt/slurm/etc/slurm.conf
    export SLURM_CONF
    SBIN=/opt/slurm/bin

    # Find burst nodes (nodes in any burst partition — anything except 'local')
    DOWN_BURST=\$(\$SBIN/sinfo -h -o '%T %N' 2>/dev/null | grep -E '^(down|drain|fail)' | \
      while read state nodes; do
        # Check if these nodes are burst nodes (not compute nodes)
        echo \$nodes | grep -E '[a-z]+-burst-' && true || true
      done | tr '\n' ',')
    DOWN_BURST=\${DOWN_BURST%,}

    if [ -n \"\$DOWN_BURST\" ]; then
      echo \"Resetting nodes: \$DOWN_BURST\"
      sudo SLURM_CONF=\$SLURM_CONF \$SBIN/scontrol update NodeName=\"\$DOWN_BURST\" State=idle 2>/dev/null || \
        echo '[WARN] scontrol update failed — nodes may recover via ReturnToService=2'
    else
      echo 'No down/failed burst nodes in Slurm.'
    fi

    echo 'Current cluster state:'
    \$SBIN/sinfo 2>/dev/null
  " || _warn "Could not SSH to head node — Slurm node reset skipped."
fi

echo
_info "Cleanup complete."
