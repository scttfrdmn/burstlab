#!/bin/bash
# =============================================================================
# validate-cluster.sh — BurstLab post-deploy validation
#
# Run this on the head node after terraform apply completes and cloud-init
# finishes. Checks that every component is healthy before you demo anything.
#
# Usage: ssh centos@<head_node_ip> 'bash /opt/slurm/etc/validate-cluster.sh'
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

for mount in /home /opt/slurm; do
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

if munge -n | unmunge -q 2>/dev/null; then
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

# Check change_state.py cron is installed for slurm user
if crontab -l -u slurm 2>/dev/null | grep -q change_state.py; then
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

# Check cloud partition is defined (generate_conf.py output was appended)
if grep -q "PartitionName=cloud" /opt/slurm/etc/slurm.conf 2>/dev/null; then
  _pass "Cloud partition defined in slurm.conf"
else
  _fail "Cloud partition NOT in slurm.conf — did generate_conf.py run?"
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

# Check cloud partition exists
CLOUD_STATE=$(/opt/slurm/bin/sinfo -p cloud -h -o "%a" 2>/dev/null)
if [ "$CLOUD_STATE" = "up" ]; then
  _pass "cloud partition is UP"
elif [ -z "$CLOUD_STATE" ]; then
  _fail "cloud partition NOT found in sinfo"
else
  _warn "cloud partition state: $CLOUD_STATE"
fi

# Check compute nodes are IDLE (not DOWN)
COMPUTE_DOWN=$(/opt/slurm/bin/sinfo -p local -h -o "%T %N" 2>/dev/null | grep -c down || true)
if [ "$COMPUTE_DOWN" -eq 0 ]; then
  _pass "No compute nodes are DOWN"
else
  _warn "$COMPUTE_DOWN compute node(s) are DOWN — they may still be starting"
  _warn "  Run: scontrol show nodes | grep -A5 Reason"
fi

# Check cloud nodes are in CLOUD* state (powered off, ready to burst)
CLOUD_NODES=$(/opt/slurm/bin/sinfo -p cloud -h -o "%T %N" 2>/dev/null)
echo "Cloud nodes state:"
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
