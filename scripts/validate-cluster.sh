#!/bin/bash
# =============================================================================
# validate-cluster.sh — BurstLab post-deploy validation
#
# Run this on the head node after terraform apply completes and cloud-init
# finishes. Checks that every component is healthy before you demo anything.
#
# Usage: ssh rocky@<head_node_ip> 'bash /opt/slurm/etc/validate-cluster.sh'
#   or after SSH: bash /opt/slurm/etc/validate-cluster.sh
# =============================================================================

set -uo pipefail

PASS=0
FAIL=0
WARN=0

_pass() { echo "  [PASS] $1"; ((PASS++)); }
_fail() { echo "  [FAIL] $1"; ((FAIL++)); }
_warn() { echo "  [WARN] $1"; ((WARN++)); }
_section() { echo; echo "=== $1 ==="; }

# -----------------------------------------------------------------------------
_section "System Services"
# -----------------------------------------------------------------------------

for svc in munge mariadb slurmdbd slurmctld; do
  if systemctl is-active --quiet "$svc"; then
    _pass "$svc is running"
  else
    _fail "$svc is NOT running"
    journalctl -u "$svc" --no-pager -n 5 2>/dev/null | sed 's/^/    /'
  fi
done

# -----------------------------------------------------------------------------
_section "EFS Mounts"
# -----------------------------------------------------------------------------

for mount in /u /opt/slurm; do
  if mountpoint -q "$mount"; then
    _pass "$mount is mounted"
    # Check it's actually EFS (nfs4)
    if mount | grep -q "$mount.*nfs4"; then
      _pass "$mount is NFS/EFS type"
    else
      _warn "$mount is mounted but not NFS4 — may not be EFS"
    fi
  else
    _fail "$mount is NOT mounted"
  fi
done

# Check /opt/slurm was populated from AMI
if [ -f /opt/slurm/.burstlab-populated ]; then
  _pass "/opt/slurm populated from AMI (sentinel file present)"
else
  _fail "/opt/slurm NOT populated — head node init may not have finished"
fi

# -----------------------------------------------------------------------------
_section "Munge Authentication"
# -----------------------------------------------------------------------------

if munge -n | unmunge > /dev/null 2>&1; then
  _pass "Local munge encode/decode works"
else
  _fail "Local munge encode/decode FAILED"
fi

if [ -f /opt/slurm/etc/munge/munge.key ]; then
  _pass "Munge key is on EFS (compute/burst nodes can copy it)"
else
  _fail "Munge key NOT found on EFS at /opt/slurm/etc/munge/munge.key"
fi

# -----------------------------------------------------------------------------
_section "Plugin v2 Files"
# -----------------------------------------------------------------------------

PLUGIN_DIR="/opt/slurm/etc/aws"
for f in resume.py suspend.py change_state.py generate_conf.py common.py config.json partitions.json; do
  if [ -f "$PLUGIN_DIR/$f" ]; then
    _pass "$f exists"
  else
    _fail "$f MISSING from $PLUGIN_DIR"
  fi
done

# Verify the plugin script Python interpreter can import boto3.
# Rocky 8: /usr/local/bin/python3 wrapper (Python 3.8 + boto3)
# Rocky 9/10: system /usr/bin/python3 (3.9/3.12 with boto3 installed directly)
# We check the functional requirement (boto3 importable) rather than a specific path
# so this check works correctly on all three BurstLab generations.
for pyfile in resume.py suspend.py change_state.py generate_conf.py; do
  SHEBANG=$(head -1 "$PLUGIN_DIR/$pyfile" 2>/dev/null)
  SHEBANG_PY=$(echo "$SHEBANG" | sed 's|^#!||' | awk '{print $1}')
  if [ -z "$SHEBANG_PY" ]; then
    _warn "$pyfile: no shebang line found"
  elif "$SHEBANG_PY" -c "import boto3" 2>/dev/null; then
    _pass "$pyfile: $SHEBANG_PY can import boto3"
  else
    _fail "$pyfile: $SHEBANG_PY cannot import boto3 — plugin will fail at runtime"
    _fail "  Fix: ensure boto3 is installed for $SHEBANG_PY"
  fi
done

# Check config.json is valid JSON
if python3 -c "import json; json.load(open('$PLUGIN_DIR/config.json'))" 2>/dev/null; then
  _pass "config.json is valid JSON"
else
  _fail "config.json is NOT valid JSON"
fi

if python3 -c "import json; json.load(open('$PLUGIN_DIR/partitions.json'))" 2>/dev/null; then
  _pass "partitions.json is valid JSON"
else
  _fail "partitions.json is NOT valid JSON"
fi

# Validate partition/nodegroup names are alphanumeric (plugin requirement)
PARTITION_NAME=$(python3 -c "
import json, re, sys
data = json.load(open('$PLUGIN_DIR/partitions.json'))
for p in data['Partitions']:
    if not re.match(r'^[a-zA-Z0-9]+$', p['PartitionName']):
        print(f'BAD: {p[\"PartitionName\"]}')
        sys.exit(1)
    for ng in p['NodeGroups']:
        if not re.match(r'^[a-zA-Z0-9]+$', ng['NodeGroupName']):
            print(f'BAD: {ng[\"NodeGroupName\"]}')
            sys.exit(1)
print('OK')
" 2>/dev/null)
if [ "$PARTITION_NAME" = "OK" ]; then
  _pass "PartitionName/NodeGroupName are alphanumeric (plugin requirement)"
else
  _fail "PartitionName or NodeGroupName contains invalid characters: $PARTITION_NAME"
fi

# Check change_state.py cron is installed for slurm user.
# The cron spool file is root-owned so we use sudo (rocky has passwordless sudo).
if sudo grep -q "change_state.py" /var/spool/cron/slurm 2>/dev/null; then
  _pass "change_state.py cron is installed for slurm user"
else
  _fail "change_state.py cron NOT found for slurm user"
fi

# -----------------------------------------------------------------------------
_section "Slurm Configuration"
# -----------------------------------------------------------------------------

if [ -f /opt/slurm/etc/slurm.conf ]; then
  _pass "slurm.conf exists at /opt/slurm/etc/slurm.conf"
else
  _fail "slurm.conf NOT found"
fi

# Check required directives are present
for directive in "PrivateData=CLOUD" "ReturnToService=2" "DebugFlags=NO_CONF_HASH" \
                  "ResumeProgram" "SuspendProgram" "SuspendTime" "ResumeTimeout"; do
  if grep -qi "^$directive" /opt/slurm/etc/slurm.conf 2>/dev/null; then
    _pass "slurm.conf has $directive"
  else
    _fail "slurm.conf MISSING $directive"
  fi
done

# Detect burst partition name from partitions.json (Gen 1=aws, Gen 2/3=cloud)
BURST_PARTITION=$(python3 -c "
import json, sys
try:
    data = json.load(open('$PLUGIN_DIR/partitions.json'))
    print(data['Partitions'][0]['PartitionName'])
except Exception as e:
    print('unknown', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)

# Check burst partition is defined in slurm.conf (generate_conf.py output was appended)
if [ -n "$BURST_PARTITION" ] && grep -q "PartitionName=${BURST_PARTITION}" /opt/slurm/etc/slurm.conf 2>/dev/null; then
  _pass "Burst partition '${BURST_PARTITION}' defined in slurm.conf"
else
  _fail "Burst partition NOT in slurm.conf — did generate_conf.py run? (expected PartitionName=${BURST_PARTITION:-unknown})"
fi

# -----------------------------------------------------------------------------
_section "Slurm Cluster State"
# -----------------------------------------------------------------------------

echo "sinfo output:"
/opt/slurm/bin/sinfo 2>/dev/null | sed 's/^/  /' || _fail "sinfo failed"

# Check local partition is up
LOCAL_STATE=$(/opt/slurm/bin/sinfo -p local -h -o "%a" 2>/dev/null)
if [ "$LOCAL_STATE" = "up" ]; then
  _pass "local partition is UP"
else
  _warn "local partition state: ${LOCAL_STATE:-unknown}"
fi

# Check burst partition exists in sinfo
CLOUD_STATE=$(/opt/slurm/bin/sinfo -p "${BURST_PARTITION:-aws}" -h -o "%a" 2>/dev/null)
if [ "$CLOUD_STATE" = "up" ]; then
  _pass "burst partition '${BURST_PARTITION}' is UP"
elif [ -z "$CLOUD_STATE" ]; then
  _fail "burst partition '${BURST_PARTITION:-aws}' NOT found in sinfo"
else
  _warn "burst partition '${BURST_PARTITION}' state: $CLOUD_STATE"
fi

# Check compute nodes are IDLE (not DOWN)
COMPUTE_DOWN=$(/opt/slurm/bin/sinfo -p local -h -o "%T %N" 2>/dev/null | grep -c down || true)
if [ "$COMPUTE_DOWN" -eq 0 ]; then
  _pass "No compute nodes are DOWN"
else
  _warn "$COMPUTE_DOWN compute node(s) are DOWN — they may still be starting"
  _warn "  Run: scontrol show nodes | grep -A5 Reason"
fi

# Check burst nodes are in CLOUD* state (powered off, ready to burst)
CLOUD_NODES=$(/opt/slurm/bin/sinfo -p "${BURST_PARTITION:-aws}" -h -o "%T %N" 2>/dev/null)
echo "Burst nodes state:"
echo "$CLOUD_NODES" | sed 's/^/  /'

# -----------------------------------------------------------------------------
_section "Slurm Accounting (slurmdbd)"
# -----------------------------------------------------------------------------

# Check cluster is registered in accounting
CLUSTER=$(/opt/slurm/bin/sacctmgr -n list cluster 2>/dev/null | awk '{print $1}' | head -1)
if [ -n "$CLUSTER" ]; then
  _pass "Cluster '$CLUSTER' registered in accounting"
else
  _fail "No cluster registered in sacctmgr — jobs will fail accounting checks"
fi

# Check alice is a registered user (required for job submission with AccountingStorageEnforce)
if /opt/slurm/bin/sacctmgr -n show user alice 2>/dev/null | grep -q "alice"; then
  _pass "alice is registered in Slurm accounting"
else
  _fail "alice is NOT in Slurm accounting — sbatch will fail"
  _fail "  Fix: sacctmgr -i add user alice account=default"
fi

# -----------------------------------------------------------------------------
_section "Summary"
# -----------------------------------------------------------------------------

echo
echo "Results: $PASS passed, $WARN warnings, $FAIL failed"
echo

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  echo "Cluster is ready. Run demo-burst.sh to test bursting."
elif [ "$FAIL" -eq 0 ]; then
  echo "Cluster is functional with warnings. Review above before demoing."
else
  echo "Cluster has failures. Check /var/log/burstlab-init.log for init errors."
  echo "Also check: journalctl -u slurmctld --no-pager -n 50"
  exit 1
fi
