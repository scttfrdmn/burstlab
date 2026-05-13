#!/bin/bash
# =============================================================================
# head-node-init.sh — BurstLab Gen 1 head node cloud-init
#
# What this script does (in order):
#   1. Fix CentOS 8 EOL repos to vault.centos.org
#   2. Set hostname
#   3. Configure NAT (iptables MASQUERADE, no firewall service — services have DROP defaults)
#   4. Mount EFS: /home and /opt/slurm
#   5. Populate /opt/slurm on EFS from the AMI if first boot
#   6. Configure munge key
#   7. Write Slurm config files from Terraform-rendered templates
#   8. Configure MariaDB for slurmdbd
#   9. Start munge → mariadb → slurmdbd → slurmctld
#  10. Install and configure Plugin v2
#  11. Run generate_conf.py, append burst node config to slurm.conf
#  12. Add change_state.py cron
#
# Terraform templatefile() substitutions: lowercase_vars are injected at deploy time.
# =============================================================================

set -euo pipefail
exec > >(tee /var/log/burstlab-init.log) 2>&1
echo "=== BurstLab head node init started: $(date) ==="


# -----------------------------------------------------------------------------
# 1. Detect OS family and fix repos if needed
# -----------------------------------------------------------------------------
echo "--- Checking OS and fixing repos if needed ---"
OS_ID=$(. /etc/os-release && echo "$ID")
OS_FAMILY="rhel"
if [ "$OS_ID" = "ubuntu" ] || [ "$OS_ID" = "debian" ]; then
  OS_FAMILY="debian"
fi

# CentOS 8: redirect EOL repos to vault.centos.org.
# Rocky Linux: repos are active, no fix needed.
if [ "$OS_ID" = "centos" ]; then
  echo "CentOS 8 detected — redirecting to vault.centos.org"
  sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*.repo
  sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo
  dnf clean all
else
  echo "$OS_ID detected — repos are active, no vault redirect needed"
fi

# Refresh package cache
if [ "$OS_FAMILY" = "rhel" ]; then
  dnf makecache --refresh || true
else
  apt-get update -y || true
fi

# -----------------------------------------------------------------------------
# 1b. Ensure cluster users exist with pinned UID/GID
# alice (UID/GID 2000) is the demo HPC user. Her home is on EFS (/home/alice)
# and is created in step 4. We create the user entry here so that UID/GID 2000
# is consistent across all nodes regardless of whether it's in the AMI.
# -----------------------------------------------------------------------------
getent group  alice >/dev/null 2>&1 || groupadd  -g 2000 alice
getent passwd alice >/dev/null 2>&1 || useradd -M -u 2000 -g alice -s /bin/bash -d /home/alice alice
# Correct home dir if AMI was built with legacy /u/home/alice path
getent passwd alice | grep -q '/u/home/alice' && usermod -d /home/alice alice || true

# -----------------------------------------------------------------------------
# 2. Set hostname
# -----------------------------------------------------------------------------
echo "--- Setting hostname ---"
hostnamectl set-hostname headnode
echo "127.0.0.1 headnode" >> /etc/hosts
# Compute node entries — all nodes need to resolve each other by short name
%{ for i in range(compute_node_count) ~}
echo "${cidrhost(onprem_cidr, i + 10)} compute${format("%02d", i + 1)}" >> /etc/hosts
%{ endfor ~}

# -----------------------------------------------------------------------------
# 3. Configure NAT (head node as cluster gateway)
# -----------------------------------------------------------------------------
echo "--- Configuring NAT ---"
# Root cause of SSH instability: both iptables-services and nftables.service ship
# default configs with DROP/REJECT catch-all rules. When either service starts or
# restarts, it clobbers the in-memory ACCEPT rules and kills SSH.
# Fix: disable BOTH services, apply MASQUERADE directly via iptables, then save
# rules to /etc/sysconfig/iptables-burstlab.rules and restore via a dedicated
# systemd service (burstlab-nat.service) on every boot. No service with DROP
# defaults ever runs.

# Disable both firewall services so they can never reload DROP rules
systemctl stop iptables 2>/dev/null || true
systemctl disable iptables 2>/dev/null || true
systemctl stop nftables 2>/dev/null || true
systemctl disable nftables 2>/dev/null || true

# Enable IP forwarding persistently
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-burstlab-forward.conf
sysctl -p /etc/sysctl.d/99-burstlab-forward.conf

# Flush all rules and set permissive defaults (ACCEPT everything)
iptables -F
iptables -F -t nat
iptables -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Add MASQUERADE rules for cluster subnets — rules stay in memory, no service
ETH=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
[ -z "$ETH" ] && ETH=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')
[ -z "$ETH" ] && { echo "FATAL: could not detect network interface for NAT"; exit 1; }
echo "Using interface $ETH for NAT masquerade"
iptables -t nat -A POSTROUTING -s ${onprem_cidr} -o "$ETH" -j MASQUERADE
iptables -t nat -A POSTROUTING -s ${cloud_cidr_a} -o "$ETH" -j MASQUERADE
iptables -t nat -A POSTROUTING -s ${cloud_cidr_b} -o "$ETH" -j MASQUERADE
echo "NAT configured on $ETH"

# Persist NAT rules so they survive head node reboot.
# We don't use iptables-services (it has DROP defaults that kill SSH), so we
# save the rules manually and restore them via a dedicated systemd service.
# RHEL: /etc/sysconfig/iptables-burstlab.rules
# Ubuntu: /etc/iptables-burstlab.rules
if [ "$OS_FAMILY" = "rhel" ]; then
  RULES_PATH="/etc/sysconfig/iptables-burstlab.rules"
else
  RULES_PATH="/etc/iptables-burstlab.rules"
fi
iptables-save > "$RULES_PATH"
cat > /etc/systemd/system/burstlab-nat.service << NATSERVICE
[Unit]
Description=BurstLab NAT rules (iptables masquerade for cluster nodes)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore $RULES_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
NATSERVICE
systemctl enable burstlab-nat.service
echo "NAT rules persisted to $RULES_PATH"

# -----------------------------------------------------------------------------
# 4. Mount EFS
# -----------------------------------------------------------------------------
echo "--- Mounting EFS via NFSv4.1 ---"
# EFS is mounted using plain nfs4 (nfs-utils). No amazon-efs-utils needed on Rocky/CentOS.
# /home       — cluster user home directories (EFS /home subpath).
# /opt/slurm  — Slurm binaries, configs, and plugin (EFS).
mkdir -p /opt/slurm

# /home — cluster user home directories.
# Mounts the EFS /home subdirectory at /home. During bootstrap (below) we create
# /home/rocky in EFS and inject rocky's SSH key there before this mount goes live,
# so rocky's home is on EFS and SSH access works regardless of /home/rocky on local disk.
# nofail: don't block boot if EFS is temporarily unavailable.
# x-systemd.requires/after=network-online.target: wait for DNS before systemd tries
# to start the mount unit, preventing the race condition where systemd picks up the
# new fstab entry mid-boot before DNS is resolvable.
echo "${efs_dns_name}:/home /home nfs4 _netdev,nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,nofail,x-systemd.requires=network-online.target,x-systemd.after=network-online.target 0 0" >> /etc/fstab

# /opt/slurm — Slurm binaries, configs, and plugin shared across all nodes
echo "${efs_dns_name}:/slurm /opt/slurm nfs4 _netdev,nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,nofail,x-systemd.requires=network-online.target,x-systemd.after=network-online.target 0 0" >> /etc/fstab

# Determine SSH user based on OS family (rocky for RHEL/Rocky, ubuntu for Ubuntu)
if [ "$OS_FAMILY" = "debian" ]; then
  SSH_USER="ubuntu"
else
  SSH_USER="rocky"
fi

# Read the EC2 key pair's public key from IMDS before the bootstrap mount.
# We inject it into EFS /home/$SSH_USER during bootstrap so the SSH user can SSH in
# after /home is mounted from EFS (which shadows any local /home/$SSH_USER).
_IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300" || true)
_EC2_PUBKEY=$(curl -sf -H "X-aws-ec2-metadata-token: $_IMDS_TOKEN" \
  "http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key" || true)

# Bootstrap: create EFS subdirectories if they don't exist.
# NFSv4 subpath mounts require the directories to exist on the server first.
# Mount EFS root temporarily, create /slurm and /home dirs, then unmount.
mkdir -p /mnt/efs-bootstrap
_EFS_BOOTSTRAP_MOUNTED=0
for attempt in $(seq 1 30); do
  mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport \
    "${efs_dns_name}:/" /mnt/efs-bootstrap && { _EFS_BOOTSTRAP_MOUNTED=1; break; } || {
    echo "EFS bootstrap mount attempt $attempt/30 failed, retrying in 20s..."
    sleep 20
  }
done
if [ "$_EFS_BOOTSTRAP_MOUNTED" = "1" ]; then
  mkdir -p /mnt/efs-bootstrap/slurm
  mkdir -p /mnt/efs-bootstrap/home/alice
  mkdir -p /mnt/efs-bootstrap/home/$SSH_USER/.ssh
  # Inject SSH user's key into EFS during bootstrap so it's present before /home mounts
  if [ -n "$_EC2_PUBKEY" ]; then
    echo "$_EC2_PUBKEY" > /mnt/efs-bootstrap/home/$SSH_USER/.ssh/authorized_keys
    chmod 600 /mnt/efs-bootstrap/home/$SSH_USER/.ssh/authorized_keys
    chmod 700 /mnt/efs-bootstrap/home/$SSH_USER/.ssh
    chown -R $SSH_USER:$SSH_USER /mnt/efs-bootstrap/home/$SSH_USER
  fi
  umount /mnt/efs-bootstrap
  echo "EFS /slurm and /home directories ensured."
else
  echo "FATAL: EFS bootstrap mount failed after 30 attempts (10 minutes) — cannot continue."
  exit 1
fi
rmdir /mnt/efs-bootstrap 2>/dev/null || true

# Mount EFS — retry loop because EFS mount target DNS may take several minutes to propagate
for dir in /home /opt/slurm; do
  for attempt in $(seq 1 30); do
    mount "$dir" && break || {
      echo "EFS mount attempt $attempt/30 for $dir failed, retrying in 20s..."
      sleep 20
    }
  done
  mountpoint -q "$dir" || { echo "FATAL: could not mount $dir after 30 attempts"; exit 1; }
done

# Set up alice's home directory on EFS (/home/alice).
# alice is the cluster demo user (UID 2000, created in AMI).
# Her home is on EFS so it's accessible from all nodes — head, compute, burst.
# Install the same EC2 key pair so alice can SSH in directly.
if mountpoint -q /home; then
  mkdir -p /home/alice/.ssh
  getent passwd alice >/dev/null 2>&1 && chown alice:alice /home/alice || true
  chmod 700 /home/alice
  if [ -n "$_EC2_PUBKEY" ]; then
    echo "$_EC2_PUBKEY" > /home/alice/.ssh/authorized_keys
    chown -R alice:alice /home/alice/.ssh
    chmod 700 /home/alice/.ssh
    chmod 600 /home/alice/.ssh/authorized_keys
    echo "SSH key installed for alice."
  fi
  # Workload job output and results directories
  mkdir -p /home/alice/logs /home/alice/results
  chown alice:alice /home/alice/logs /home/alice/results
  echo "Created /home/alice home directory on EFS."
fi

# -----------------------------------------------------------------------------
# 5. Populate /opt/slurm on EFS from AMI (first boot only)
# -----------------------------------------------------------------------------
echo "--- Populating EFS /opt/slurm from AMI ---"
# The AMI has Slurm pre-installed under /opt/slurm-baked. We rsync it to
# the EFS mount on first boot. Subsequent nodes just mount and find it ready.
if [ ! -f /opt/slurm/.burstlab-populated ]; then
  echo "First boot: copying Slurm binaries to EFS..."
  rsync -a /opt/slurm-baked/ /opt/slurm/
  echo "EFS /opt/slurm populated from AMI."
else
  echo "EFS /opt/slurm already populated, skipping."
fi

# Create required directories on EFS
mkdir -p /opt/slurm/etc/aws
mkdir -p /opt/slurm/etc/munge

# Create Slurm spool and log dirs (local to each node, not on EFS)
mkdir -p /var/spool/slurm/ctld /var/spool/slurm/d
mkdir -p /var/log/slurm
chown slurm:slurm /var/spool/slurm/ctld /var/spool/slurm/d /var/log/slurm
# Pre-create log files owned by slurm. With SlurmUser=slurm in slurm.conf,
# slurmctld drops to the slurm user after startup and must be able to write its
# own log. resume.py/suspend.py also run under slurmctld's user, so aws_plugin.log
# must also be slurm-owned. Without pre-creation, the first run creates them as
# root, and the slurm user can never write to them.
touch /var/log/slurm/slurmctld.log
touch /var/log/slurm/aws_plugin.log
chown slurm:slurm /var/log/slurm/slurmctld.log /var/log/slurm/aws_plugin.log

# -----------------------------------------------------------------------------
# 6. Configure munge
# -----------------------------------------------------------------------------
echo "--- Configuring munge ---"
# Write the munge key (generated by Terraform, base64 encoded)
echo "${munge_key_b64}" | base64 -d > /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 0400 /etc/munge/munge.key

# Also store on EFS so it's accessible as a backup
cp /etc/munge/munge.key /opt/slurm/etc/munge/munge.key
chmod 0400 /opt/slurm/etc/munge/munge.key
# Sentinel written HERE (after munge key) — compute/burst nodes poll for this.
# Must come after both rsync AND munge key write so any node seeing the sentinel
# is guaranteed to find both Slurm binaries AND the munge key on EFS.
touch /opt/slurm/.burstlab-populated

systemctl enable munge
systemctl start munge
systemctl is-active munge || { echo "FATAL: munge failed to start"; exit 1; }

# -----------------------------------------------------------------------------
# 7. Write Slurm config files
# -----------------------------------------------------------------------------
echo "--- Writing Slurm configs ---"
mkdir -p /opt/slurm/etc

# slurm.conf (rendered by Terraform, burst_node_conf filled in later)
cat > /opt/slurm/etc/slurm.conf << 'SLURMCONF'
${slurm_conf}
SLURMCONF

# slurmdbd.conf (contains DB password — 0600 required)
cat > /opt/slurm/etc/slurmdbd.conf << 'SLURMDBDCONF'
${slurmdbd_conf}
SLURMDBDCONF
chmod 0600 /opt/slurm/etc/slurmdbd.conf
chown slurm:slurm /opt/slurm/etc/slurmdbd.conf

# cgroup.conf
cat > /opt/slurm/etc/cgroup.conf << 'CGROUPCONF'
${cgroup_conf}
CGROUPCONF

# Symlink so Slurm finds configs at the standard path it was compiled with
ln -sfn /opt/slurm/etc/slurm.conf /etc/slurm/slurm.conf 2>/dev/null || true

# -----------------------------------------------------------------------------
# 8. Configure MariaDB for slurmdbd
# -----------------------------------------------------------------------------
echo "--- Configuring MariaDB ---"
systemctl enable mariadb
systemctl start mariadb

mysql -u root << MYSQLEOF
CREATE DATABASE IF NOT EXISTS slurm_acct_db;
CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY '${slurmdbd_db_password}';
GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'localhost';
FLUSH PRIVILEGES;
MYSQLEOF

# -----------------------------------------------------------------------------
# 9. Start Slurm services
# -----------------------------------------------------------------------------
echo "--- Starting Slurm services ---"
systemctl enable slurmdbd
systemctl start slurmdbd

# Wait for slurmdbd to fully initialize DB schema.
# On first boot slurmdbd creates all tables — can take 10-20s.
# Check: SLURM_CONF must be set inline (profile.d not yet sourced in cloud-init).
# Use 'show account' not 'show cluster' — fresh DB has no clusters yet, so
# 'show cluster' returns empty output. We check exit code (0 = connected), not content.
echo "Waiting for slurmdbd to be ready..."
for attempt in $(seq 1 30); do
  SLURM_CONF=/opt/slurm/etc/slurm.conf /opt/slurm/bin/sacctmgr -n show account > /dev/null 2>&1 && break
  echo "  slurmdbd not ready yet (attempt $attempt/30), waiting 5s..."
  sleep 5
done
SLURM_CONF=/opt/slurm/etc/slurm.conf /opt/slurm/bin/sacctmgr -n show account > /dev/null 2>&1 || {
  echo "FATAL: slurmdbd failed to become ready after 150s"
  journalctl -u slurmdbd --no-pager -n 30
  exit 1
}
echo "slurmdbd is ready."

systemctl enable slurmctld
# slurmctld may fail on first start because burst node definitions are not
# yet in slurm.conf (generate_conf.py appends them in step 11). We allow
# the failure here and do a hard restart after generate_conf.py completes.
systemctl start slurmctld || echo "[WARN] slurmctld did not start on first attempt — will retry after generate_conf.py"
sleep 3

systemctl is-active slurmdbd || { echo "FATAL: slurmdbd failed"; journalctl -u slurmdbd --no-pager -n 30; exit 1; }

# Create the default Slurm account (required for job submission)
export SLURM_CONF=/opt/slurm/etc/slurm.conf
/opt/slurm/bin/sacctmgr -i add cluster ${cluster_name} || true
/opt/slurm/bin/sacctmgr -i add account default description="Default account" organization="BurstLab" || true
/opt/slurm/bin/sacctmgr -i add user root  account=default || true
/opt/slurm/bin/sacctmgr -i add user alice account=default || true

# -----------------------------------------------------------------------------
# 10. Install Plugin v2
# -----------------------------------------------------------------------------
echo "--- Installing AWS Plugin for Slurm v2 ---"
cd /opt/slurm/etc/aws
if [ ! -d /opt/slurm/etc/aws/.git ]; then
  git clone --branch plugin-v2 --depth 1 \
    https://github.com/aws-samples/aws-plugin-for-slurm.git .
else
  echo "Plugin already installed on EFS, skipping git clone."
fi

chmod +x resume.py suspend.py change_state.py generate_conf.py

# Patch plugin script shebangs to use a Python interpreter that has boto3.
# Rocky 8: system python3 (3.6) lacks boto3 — patch to /usr/local/bin/python3 (3.8 wrapper).
# Rocky 9/10: system python3 (3.9/3.12) has boto3 installed directly — no patch needed.
_OS_MAJOR=$(. /etc/os-release && echo "$${VERSION_ID%%.*}")
if [ "$_OS_MAJOR" = "8" ]; then
  for _pf in resume.py suspend.py change_state.py generate_conf.py common.py; do
    [ -f "$_pf" ] && sed -i 's|#!/usr/bin/python3|#!/usr/local/bin/python3|g' "$_pf" 2>/dev/null || true
    [ -f "$_pf" ] && sed -i 's|#!/usr/bin/env python3|#!/usr/local/bin/python3|g' "$_pf" 2>/dev/null || true
  done
  echo "Rocky 8: patched plugin shebangs to /usr/local/bin/python3 (Python 3.8 with boto3)"
else
  echo "Rocky $${_OS_MAJOR}: system python3 has boto3, shebang patch not needed"
fi

# Fix change_state.py rule #3: upstream uses "'POWER' in node_states" which is a
# list-membership check and never matches because Slurm emits "POWERED_DOWN" not "POWER".
# Patch to any('POWER' in s for s in node_states) so POWERED_DOWN, POWER_DOWN, etc. all match.
# This ensures DOWN+CLOUD+POWERED_DOWN nodes (e.g. after ResumeTimeout) get auto-reset to IDLE.
sed -i \
  "s|'POWER' in node_states|any('POWER' in s for s in node_states)|g" \
  change_state.py 2>/dev/null || true

# Write plugin config.json (rendered by Terraform)
cat > /opt/slurm/etc/aws/config.json << 'PLUGINCONF'
${plugin_config_json}
PLUGINCONF

# Write partitions.json (rendered by Terraform with actual subnet IDs, etc.)
cat > /opt/slurm/etc/aws/partitions.json << 'PARTITIONSCONF'
${partitions_json}
PARTITIONSCONF

# -----------------------------------------------------------------------------
# 11. Generate burst node config and append to slurm.conf
# -----------------------------------------------------------------------------
echo "--- Generating burst node config ---"
cd /opt/slurm/etc/aws
python3 generate_conf.py || {
  echo "FATAL: generate_conf.py failed — burst nodes will not be configured."
  echo "Common causes: boto3 not installed, invalid partitions.json, wrong python3 path."
  python3 -c "import boto3" 2>&1 | sed 's/^/  boto3 check: /' || true
  echo "  python3 is: $(which python3) ($(python3 --version 2>&1))"
  exit 1
}

# Append only NodeName/PartitionName lines from slurm.conf.aws to slurm.conf.
# generate_conf.py also outputs plugin directives (PrivateData, ResumeProgram, etc.)
# which are already in the base slurm.conf template — appending them again causes
# "specified more than once" fatal errors. We extract only the node/partition lines.
if [ -f slurm.conf.aws ]; then
  echo "slurm.conf.aws generated:"
  cat slurm.conf.aws
  # Wrap with sentinels so manage-partitions.sh can replace this section cleanly.
  echo "# BEGIN BURST PARTITIONS — managed by manage-partitions.sh" >> /opt/slurm/etc/slurm.conf
  grep -E "^(NodeName|PartitionName)=" slurm.conf.aws >> /opt/slurm/etc/slurm.conf
  echo "# END BURST PARTITIONS" >> /opt/slurm/etc/slurm.conf
  echo "Appended NodeName/PartitionName lines to slurm.conf."
fi

# Copy gres.conf if generated (needed even if empty)
[ -f gres.conf.aws ] && cp gres.conf.aws /opt/slurm/etc/gres.conf || touch /opt/slurm/etc/gres.conf

# Start or reload slurmctld now that burst node config is in slurm.conf
sleep 2
export SLURM_CONF=/opt/slurm/etc/slurm.conf
if systemctl is-active slurmctld; then
  /opt/slurm/bin/scontrol reconfigure || systemctl restart slurmctld
else
  systemctl start slurmctld
  sleep 3
  systemctl is-active slurmctld || { echo "FATAL: slurmctld failed after generate_conf"; journalctl -u slurmctld --no-pager -n 50; exit 1; }
fi

# Set SLURM_CONF globally so interactive tools (sinfo, scontrol, etc.) work
# without needing the env var set manually. The systemd service already has it,
# but shell sessions need it via profile.d.
cat > /etc/profile.d/slurm.sh << 'SLURMPROFILE'
export SLURM_CONF=/opt/slurm/etc/slurm.conf
export PATH=/opt/slurm/bin:/opt/slurm/sbin:$PATH
SLURMPROFILE
chmod 644 /etc/profile.d/slurm.sh

# -----------------------------------------------------------------------------
# 12. Install change_state.py cron
# -----------------------------------------------------------------------------
echo "--- Installing change_state.py cron ---"
# Must run as slurm user: with SlurmUser=slurm in slurm.conf, slurmctld drops to
# the slurm user after startup, and scontrol node updates are permitted for the
# SlurmUser. SLURM_CONF must be set explicitly as a crontab env var — cron
# inherits a minimal environment that does not include it.
# Note: `crontab -l` exits 1 when no crontab exists; `|| true` prevents that
# from clearing the crontab instead of appending to it.
(crontab -u slurm -l 2>/dev/null || true; printf 'SLURM_CONF=/opt/slurm/etc/slurm.conf\n* * * * * /opt/slurm/etc/aws/change_state.py >> /var/log/slurm/change_state.log 2>&1\n') | crontab -u slurm - || \
  echo "[WARN] crontab install for slurm user failed — change_state.py cron not active"

# -----------------------------------------------------------------------------
# 13. Deploy helper scripts to EFS
# -----------------------------------------------------------------------------
echo "--- Deploying helper scripts from S3 ---"
# validate-cluster.sh and demo-burst.sh are stored in S3 (not embedded in
# UserData) to stay well under the 16 KB EC2 UserData limit. The head node
# IAM role has s3:GetObject on this bucket.
aws s3 cp "s3://${scripts_bucket_name}/validate-cluster.sh" /opt/slurm/etc/validate-cluster.sh
aws s3 cp "s3://${scripts_bucket_name}/demo-burst.sh" /opt/slurm/etc/demo-burst.sh
chmod 755 /opt/slurm/etc/validate-cluster.sh /opt/slurm/etc/demo-burst.sh

echo "Helper scripts deployed to /opt/slurm/etc/"
echo "(manage-partitions.sh is deployed separately — see scripts/deploy-admin-tools.sh)"

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo "=== BurstLab head node init complete: $(date) ==="
echo ""
echo "Cluster status:"
/opt/slurm/bin/sinfo || true
