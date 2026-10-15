#!/bin/bash
# =============================================================================
# apply-config.sh — apply Terraform-rendered Slurm/plugin config to a running
# head node
#
# The head node's user_data is in ignore_changes (re-running init would wipe the
# cluster), so config changes made after the first `terraform apply` — e.g.
# max_burst_nodes, burst_node_instance_type, slurm.conf template edits — reach the
# cluster through this script instead. Terraform uploads the rendered configs to
# the cluster's scripts bucket and null_resource.config_push runs this on the
# head node via SSM Run Command (see scripts/push-config.sh).
#
# It repeats init step 11 (head-node-init.sh.tpl): write the base configs,
# regenerate burst node definitions from partitions.json with generate_conf.py,
# rebuild the BEGIN/END BURST PARTITIONS block, then restart slurmctld and
# `scontrol reconfigure` so every slurmd re-reads slurm.conf from EFS.
#
# NOTE: partitions.json is replaced with Terraform's version, so partitions added
# on the cluster with manage-partitions.sh are dropped by a push.
#
# Usage (root, on the head node):
#   bash apply-config.sh <scripts_bucket> <region>
# =============================================================================

set -euo pipefail

BUCKET="${1:?usage: apply-config.sh <scripts_bucket> <region>}"
REGION="${2:?usage: apply-config.sh <scripts_bucket> <region>}"
ETC=/opt/slurm/etc
PLUGIN_DIR=$ETC/aws
export SLURM_CONF=$ETC/slurm.conf
export PATH=/usr/local/bin:/opt/slurm/bin:/opt/slurm/sbin:$PATH

# On first apply the head node is still initialising, and init writes these same
# configs itself. Applying now would race it.
if ! grep -q 'head node init complete' /var/log/burstlab-init.log 2>/dev/null; then
  echo "Head node init has not completed — it writes these configs itself. Nothing to push."
  exit 0
fi

# Gen 1 (Rocky 8) runs the plugin with the /usr/local/bin/python3 wrapper (boto3).
if [ -x /usr/local/bin/python3 ]; then PYTHON3=/usr/local/bin/python3; else PYTHON3=/usr/bin/python3; fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
for f in slurm.conf cgroup.conf partitions.json config.json; do
  aws s3 cp --quiet --region "$REGION" "s3://$BUCKET/config/$f" "$STAGE/$f"
done

# Keep the current config so a bad push can be rolled back.
BACKUP="$ETC/config-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
cp -p "$ETC/slurm.conf" "$ETC/cgroup.conf" "$PLUGIN_DIR/partitions.json" "$PLUGIN_DIR/config.json" "$BACKUP/"
echo "Backed up current config to $BACKUP"

_restore() {
  echo "Restoring config from $BACKUP" >&2
  cp -p "$BACKUP/slurm.conf" "$BACKUP/cgroup.conf" "$ETC/"
  cp -p "$BACKUP/partitions.json" "$BACKUP/config.json" "$PLUGIN_DIR/"
  systemctl restart slurmctld || true
}

install -m 0644 "$STAGE/cgroup.conf" "$ETC/cgroup.conf"
install -m 0644 "$STAGE/partitions.json" "$PLUGIN_DIR/partitions.json"
install -m 0644 "$STAGE/config.json" "$PLUGIN_DIR/config.json"

# Regenerate burst node definitions and append only the NodeName/PartitionName
# lines — the plugin directives generate_conf.py also emits are already in the
# base slurm.conf, and repeating them is a fatal "specified more than once".
cd "$PLUGIN_DIR"
"$PYTHON3" generate_conf.py || { echo "generate_conf.py failed" >&2; _restore; exit 1; }
{
  cat "$STAGE/slurm.conf"
  echo "# BEGIN BURST PARTITIONS — managed by manage-partitions.sh"
  grep -E "^(NodeName|PartitionName)=" slurm.conf.aws || true
  echo "# END BURST PARTITIONS"
} > "$STAGE/slurm.conf.new"
[ -f gres.conf.aws ] && cp gres.conf.aws "$ETC/gres.conf"
install -m 0644 "$STAGE/slurm.conf.new" "$ETC/slurm.conf"

# Node definitions may have changed (e.g. a new burst node range), which needs a
# controller restart; reconfigure then makes every slurmd re-read slurm.conf.
systemctl restart slurmctld
sleep 3
if ! systemctl is-active --quiet slurmctld; then
  echo "slurmctld failed to start with the new config:" >&2
  journalctl -u slurmctld --no-pager -n 30 >&2 || true
  _restore
  exit 1
fi
scontrol reconfigure || echo "[WARN] scontrol reconfigure failed — slurmds pick up slurm.conf on their next restart"

echo "Config applied. Burst partitions now in slurm.conf:"
grep -E "^(NodeName|PartitionName)=" "$ETC/slurm.conf" | grep -v '^NodeName=compute\|^PartitionName=local' || true
