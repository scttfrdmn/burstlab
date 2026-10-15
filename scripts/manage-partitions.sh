#!/bin/bash
# =============================================================================
# manage-partitions.sh — BurstLab burst partition manager
#
# Add or remove burst partitions from a running cluster without redeploying.
# New partitions reuse the existing EC2 launch template (same AMI, network,
# security groups) and only override the instance type and purchasing option.
#
# Usage:
#   manage-partitions.sh add <partition> <nodegroup> <instance_type> [OPTIONS]
#   manage-partitions.sh remove <partition>
#   manage-partitions.sh list
#
# Options for 'add':
#   --spot              Use Spot instances (default: on-demand)
#   --max-nodes N       Max burst nodes for this partition (default: 10)
#   --cpus N            CPUs per node (default: the instance type's vCPU count)
#   --memory MB         RealMemory in MB (default: ~95% of the instance type's
#                       memory, rounded down to 1000 — 32 GiB → 31000, matching
#                       the generation templates; the rest is OS headroom)
#   --max-time HH:MM:SS Max job time (default: 4:00:00)
#
# Node naming: {partition}-{nodegroup}-{index}
# Example: partition=gpu nodegroup=g5xl → nodes gpu-g5xl-0, gpu-g5xl-1, ...
#
# Restrictions:
#   - partition and nodegroup must be alphanumeric only (Plugin v2 requirement)
#   - 'local' is reserved for on-prem static compute nodes
#
# Requires: root or passwordless sudo. Run on the head node.
#
# NOTE: partitions added here live only on the cluster. A later `terraform apply`
# that changes the rendered configs pushes Terraform's partitions.json
# (apply-config.sh) and drops them. For a permanent partition, edit
# configs/<gen>/partitions.json.tpl instead.
#
# Examples:
#   manage-partitions.sh add gpu g5xl g5.xlarge --spot --max-nodes 4
#   manage-partitions.sh add highmem r7a2xl r7a.2xlarge --max-nodes 2
#   manage-partitions.sh remove gpu
#   manage-partitions.sh list
# =============================================================================

set -uo pipefail
export SLURM_CONF=/opt/slurm/etc/slurm.conf
PLUGIN_DIR=/opt/slurm/etc/aws
SLURM_BIN=/opt/slurm/bin
# Gen 1 (Rocky 8) needs the /usr/local/bin/python3 wrapper — boto3 is installed for
# Python 3.8 there, not the system Python 3.6. Gen 2+ AMIs deliberately don't create
# that wrapper; their system python3 has boto3.
if [ -x /usr/local/bin/python3 ]; then PYTHON3=/usr/local/bin/python3; else PYTHON3=/usr/bin/python3; fi

_die() { echo "ERROR: $1" >&2; exit 1; }

# Must run as root or with sudo
[ "$(id -u)" -eq 0 ] || _die "This script must be run as root (sudo manage-partitions.sh ...)"

# Validate plugin dir exists
[ -d "$PLUGIN_DIR" ] || _die "Plugin directory not found: $PLUGIN_DIR"
[ -f "$PLUGIN_DIR/partitions.json" ] || _die "partitions.json not found in $PLUGIN_DIR"
[ -f "$PLUGIN_DIR/generate_conf.py" ] || _die "generate_conf.py not found in $PLUGIN_DIR"

# -----------------------------------------------------------------------------
# list — show current partitions from partitions.json
# -----------------------------------------------------------------------------
cmd_list() {
  echo "Current burst partitions (from $PLUGIN_DIR/partitions.json):"
  echo
  $PYTHON3 - << 'PYEOF'
import json, sys
data = json.load(open('/opt/slurm/etc/aws/partitions.json'))
for p in data['Partitions']:
    pname = p['PartitionName']
    for ng in p['NodeGroups']:
        ngname = ng['NodeGroupName']
        itype  = ng.get('LaunchTemplateOverrides', [{}])[0].get('InstanceType', 'unknown')
        maxn   = ng.get('MaxNodes', '?')
        opt    = ng.get('PurchasingOption', 'on-demand')
        print(f"  partition={pname}  nodegroup={ngname}  instance={itype}  max_nodes={maxn}  purchasing={opt}")
        print(f"    nodes: {pname}-{ngname}-0 ... {pname}-{ngname}-{int(maxn)-1}")
PYEOF
  echo
  echo "Live cluster state (sinfo):"
  $SLURM_BIN/sinfo 2>/dev/null | sed 's/^/  /'
}

# -----------------------------------------------------------------------------
# _rebuild_slurm_conf — regenerate burst section from partitions.json
# -----------------------------------------------------------------------------
_rebuild_slurm_conf() {
  local SLURM_CONF_PATH=/opt/slurm/etc/slurm.conf
  local SLURM_CONF_AWS="$PLUGIN_DIR/slurm.conf.aws"

  cd "$PLUGIN_DIR" || _die "cannot cd to plugin dir: $PLUGIN_DIR"
  echo "Running generate_conf.py..."
  $PYTHON3 generate_conf.py || _die "generate_conf.py failed"

  if [ ! -f "$SLURM_CONF_AWS" ]; then
    _die "generate_conf.py did not produce slurm.conf.aws"
  fi

  echo "Generated slurm.conf.aws:"
  cat "$SLURM_CONF_AWS"

  # Replace the BEGIN/END BURST PARTITIONS section in slurm.conf.
  # If sentinels don't exist (older deploy), append them.
  if grep -q "# BEGIN BURST PARTITIONS" "$SLURM_CONF_PATH"; then
    # Remove everything between sentinels (inclusive) and re-insert.
    $PYTHON3 - << PYEOF
import re

with open('$SLURM_CONF_PATH', 'r') as f:
    content = f.read()

# Extract new burst lines from slurm.conf.aws
with open('$SLURM_CONF_AWS', 'r') as f:
    burst_lines = [l for l in f if l.startswith('NodeName=') or l.startswith('PartitionName=')]

new_section = (
    '# BEGIN BURST PARTITIONS — managed by manage-partitions.sh\n'
    + ''.join(burst_lines)
    + '# END BURST PARTITIONS\n'
)

# Replace old section
updated = re.sub(
    r'# BEGIN BURST PARTITIONS.*?# END BURST PARTITIONS\n',
    new_section,
    content,
    flags=re.DOTALL
)

with open('$SLURM_CONF_PATH', 'w') as f:
    f.write(updated)
PYEOF
    echo "Updated burst partition section in slurm.conf."
  else
    # No sentinels — legacy deploy or first run by this script.
    # Strip any existing burst NodeName/PartitionName lines (avoid duplicates),
    # then add the sentinel block.
    $PYTHON3 - << PYEOF
import re

with open('$SLURM_CONF_PATH', 'r') as f:
    content = f.read()

with open('$SLURM_CONF_AWS', 'r') as f:
    burst_lines = [l for l in f if l.startswith('NodeName=') or l.startswith('PartitionName=')]

# Remove burst-related lines appended by head-node-init.sh before sentinels existed.
# Burst NodeName lines have State=CLOUD; static compute nodes have State=IDLE.
# Burst PartitionName lines are anything that isn't PartitionName=local.
stripped = re.sub(r'^NodeName=.*\bState=CLOUD\b.*\n', '', content, flags=re.MULTILINE)
stripped = re.sub(r'^PartitionName=(?!local\b).*\n', '', stripped, flags=re.MULTILINE)
stripped = stripped.rstrip('\n') + '\n'

new_section = (
    '# BEGIN BURST PARTITIONS — managed by manage-partitions.sh\n'
    + ''.join(burst_lines)
    + '# END BURST PARTITIONS\n'
)

with open('$SLURM_CONF_PATH', 'w') as f:
    f.write(stripped + new_section)
PYEOF
    echo "Converted legacy slurm.conf to sentinel-based burst partition section."
  fi

  # Reload slurmctld
  echo "Reloading slurmctld..."
  if $SLURM_BIN/scontrol reconfigure 2>/dev/null; then
    echo "slurmctld reconfigured."
  else
    echo "scontrol reconfigure failed; restarting slurmctld..."
    systemctl restart slurmctld || _die "Failed to restart slurmctld"
  fi
}

# -----------------------------------------------------------------------------
# add — add a new burst partition
# -----------------------------------------------------------------------------
cmd_add() {
  local PARTITION="${1:-}"
  local NODEGROUP="${2:-}"
  local INSTANCE_TYPE="${3:-}"
  shift 3

  [ -n "$PARTITION" ]     || _die "Usage: $0 add <partition> <nodegroup> <instance_type> [options]"
  [ -n "$NODEGROUP" ]     || _die "Usage: $0 add <partition> <nodegroup> <instance_type> [options]"
  [ -n "$INSTANCE_TYPE" ] || _die "Usage: $0 add <partition> <nodegroup> <instance_type> [options]"

  # Validate names are alphanumeric
  [[ "$PARTITION" =~ ^[a-zA-Z0-9]+$ ]] || _die "partition must be alphanumeric only (no hyphens): $PARTITION"
  [[ "$NODEGROUP" =~ ^[a-zA-Z0-9]+$ ]] || _die "nodegroup must be alphanumeric only (no hyphens): $NODEGROUP"
  [ "$PARTITION" != "local" ] || _die "'local' is reserved for on-prem static compute nodes"

  # Parse options
  SPOT=false
  MAX_NODES=10
  CPUS=""
  MEMORY=""
  MAX_TIME="4:00:00"

  while [ $# -gt 0 ]; do
    case "$1" in
      --spot)        SPOT=true ;;
      --max-nodes)   MAX_NODES="$2"; shift ;;
      --cpus)        CPUS="$2"; shift ;;
      --memory)      MEMORY="$2"; shift ;;
      --max-time)    MAX_TIME="$2"; shift ;;
      *) _die "Unknown option: $1" ;;
    esac
    shift
  done

  # Check partition doesn't already exist in partitions.json
  EXISTING=$($PYTHON3 -c "
import json
data = json.load(open('$PLUGIN_DIR/partitions.json'))
names = [p['PartitionName'] for p in data['Partitions']]
print('yes' if '$PARTITION' in names else 'no')
")
  [ "$EXISTING" = "no" ] || _die "Partition '$PARTITION' already exists. Remove it first."

  # Size nodes from the instance type unless --cpus/--memory were given. Declaring
  # more CPUs or memory than the hardware has makes slurmd register with less and
  # Slurm marks the node INVALID/drained.
  if [ -z "$CPUS" ] || [ -z "$MEMORY" ]; then
    read -r TYPE_CPUS TYPE_MEMORY <<< "$($PYTHON3 -c "
import json, boto3
region = json.load(open('$PLUGIN_DIR/partitions.json'))['Partitions'][0]['NodeGroups'][0]['Region']
it = boto3.client('ec2', region_name=region).describe_instance_types(InstanceTypes=['$INSTANCE_TYPE'])['InstanceTypes'][0]
print(it['VCpuInfo']['DefaultVCpus'], it['MemoryInfo']['SizeInMiB'] * 95 // 100 // 1000 * 1000)
" 2>/dev/null)"
    [ -n "${TYPE_CPUS:-}" ] || _die "Could not look up $INSTANCE_TYPE (ec2:DescribeInstanceTypes). Check the name, or pass --cpus N --memory MB."
    CPUS="${CPUS:-$TYPE_CPUS}"
    MEMORY="${MEMORY:-$TYPE_MEMORY}"
  fi

  # Read launch template, subnets and identity tags from the first existing partition
  # (reuse infra). The Cluster tag is what cleanup-burst-nodes.sh filters on.
  read -r LT_ID SUBNET_A SUBNET_B REGION CLUSTER_TAG GENERATION_TAG <<< "$($PYTHON3 -c "
import json
data = json.load(open('$PLUGIN_DIR/partitions.json'))
ng = data['Partitions'][0]['NodeGroups'][0]
lt = ng['LaunchTemplateSpecification']['LaunchTemplateId']
subnets = ng['SubnetIds']
region = ng['Region']
tags = {t['Key']: t['Value'] for t in ng.get('Tags', [])}
print(lt, subnets[0], subnets[1] if len(subnets) > 1 else subnets[0], region,
      tags.get('Cluster', 'unknown'), tags.get('Generation', 'unknown'))
")"

  echo "Adding partition '$PARTITION' (nodegroup '$NODEGROUP'):"
  echo "  Instance type:    $INSTANCE_TYPE"
  echo "  Purchasing:       $( [ "$SPOT" = true ] && echo spot || echo on-demand )"
  echo "  Max nodes:        $MAX_NODES"
  echo "  CPUs/node:        $CPUS"
  echo "  Memory/node:      ${MEMORY} MB"
  echo "  Max job time:     $MAX_TIME"
  echo "  Launch template:  $LT_ID"
  echo "  Subnets:          $SUBNET_A, $SUBNET_B"
  echo "  Node names:       ${PARTITION}-${NODEGROUP}-0 ... ${PARTITION}-${NODEGROUP}-$((MAX_NODES-1))"
  echo

  if [ "$SPOT" = true ]; then
    PURCHASING_OPTION='"spot"'
    SPOT_OPTIONS='"SpotOptions": { "AllocationStrategy": "lowest-price" },'
    OD_OPTIONS=""
  else
    PURCHASING_OPTION='"on-demand"'
    SPOT_OPTIONS=""
    OD_OPTIONS='"OnDemandOptions": { "AllocationStrategy": "lowest-price" },'
  fi

  # Add new partition entry to partitions.json using Python
  $PYTHON3 - << PYEOF
import json

data = json.load(open('$PLUGIN_DIR/partitions.json'))

new_partition = {
    "PartitionName": "$PARTITION",
    "NodeGroups": [
        {
            "NodeGroupName": "$NODEGROUP",
            "MaxNodes": $MAX_NODES,
            "Region": "$REGION",

            "SlurmSpecifications": {
                "CPUs": "$CPUS",
                "RealMemory": "$MEMORY",
                "Weight": "1",
                "State": "CLOUD"
            },

            "PurchasingOption": $PURCHASING_OPTION,
            $OD_OPTIONS
            $SPOT_OPTIONS

            "LaunchTemplateSpecification": {
                "LaunchTemplateId": "$LT_ID",
                "Version": "\$Latest"
            },

            "LaunchTemplateOverrides": [
                { "InstanceType": "$INSTANCE_TYPE" }
            ],

            "SubnetIds": [ "$SUBNET_A", "$SUBNET_B" ],

            "Tags": [
                { "Key": "Project",    "Value": "burstlab" },
                { "Key": "Generation", "Value": "$GENERATION_TAG" },
                { "Key": "Cluster",    "Value": "$CLUSTER_TAG" },
                { "Key": "Partition",  "Value": "$PARTITION" }
            ]
        }
    ],

    "PartitionOptions": {
        "Default": "No",
        "MaxTime": "$MAX_TIME",
        "State": "UP"
    }
}

data['Partitions'].append(new_partition)

with open('$PLUGIN_DIR/partitions.json', 'w') as f:
    json.dump(data, f, indent=2)

print("partitions.json updated.")
PYEOF

  _rebuild_slurm_conf

  echo
  echo "Done. New partition '$PARTITION' is active."
  echo "Submit jobs with: sbatch --partition=$PARTITION --wrap=\"hostname\""
}

# -----------------------------------------------------------------------------
# remove — remove a burst partition
# -----------------------------------------------------------------------------
cmd_remove() {
  local PARTITION="${1:-}"
  [ -n "$PARTITION" ] || _die "Usage: $0 remove <partition>"
  [ "$PARTITION" != "local" ] || _die "'local' partition cannot be removed (it is the on-prem static partition)"

  # Check partition exists
  EXISTING=$($PYTHON3 -c "
import json
data = json.load(open('$PLUGIN_DIR/partitions.json'))
names = [p['PartitionName'] for p in data['Partitions']]
print('yes' if '$PARTITION' in names else 'no')
")
  [ "$EXISTING" = "yes" ] || _die "Partition '$PARTITION' not found in partitions.json"

  # Check for running jobs in this partition
  RUNNING=$($SLURM_BIN/squeue -p "$PARTITION" -h -o "%i" 2>/dev/null | wc -l)
  if [ "$RUNNING" -gt 0 ]; then
    echo "WARNING: $RUNNING job(s) running or pending in partition '$PARTITION'."
    read -r -p "Cancel all and continue? [y/N] " CONFIRM
    [[ "$CONFIRM" =~ ^[yY]$ ]] || { echo "Aborted."; exit 0; }
    $SLURM_BIN/scancel -p "$PARTITION" 2>/dev/null || true
    sleep 2
  fi

  echo "Removing partition '$PARTITION' from partitions.json..."
  $PYTHON3 - << PYEOF
import json

data = json.load(open('$PLUGIN_DIR/partitions.json'))
before = len(data['Partitions'])
data['Partitions'] = [p for p in data['Partitions'] if p['PartitionName'] != '$PARTITION']
after = len(data['Partitions'])

with open('$PLUGIN_DIR/partitions.json', 'w') as f:
    json.dump(data, f, indent=2)

print(f"Removed {before - after} partition(s). {after} partition(s) remaining.")
PYEOF

  _rebuild_slurm_conf

  echo
  echo "Done. Partition '$PARTITION' removed."
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  add)    cmd_add "$@" ;;
  remove) cmd_remove "$@" ;;
  list)   cmd_list ;;
  "")     echo "Usage: $0 {add|remove|list}"; echo; echo "  add    <partition> <nodegroup> <instance_type> [--spot] [--max-nodes N] [--cpus N] [--memory MB] [--max-time HH:MM:SS]"; echo "  remove <partition>"; echo "  list"; exit 1 ;;
  *)      _die "Unknown command: $COMMAND. Use add, remove, or list." ;;
esac
