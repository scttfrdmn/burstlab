#!/bin/bash
# =============================================================================
# head-node-init.sh — BurstLab Gen 1 head node cloud-init
#
# What this script does (in order):
#   1. Fix CentOS 8 EOL repos to vault.centos.org
#   2. Set hostname
#   3. Configure iptables NAT (head node is the cluster's internet gateway)
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

# SSH key injection happens in step 4 (after EFS mount) so it persists on EFS.

# -----------------------------------------------------------------------------
# 1. Fix repos if needed
# On CentOS 8 (TCU's actual OS): redirect EOL repos to vault.centos.org.
# On Rocky Linux 8 (our AMI base): repos are active, no fix needed.
# -----------------------------------------------------------------------------
echo "--- Checking OS and fixing repos if needed ---"
OS_ID=$(. /etc/os-release && echo "$ID")
if [ "$OS_ID" = "centos" ]; then
  echo "CentOS 8 detected — redirecting to vault.centos.org"
  sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*.repo
  sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo
  dnf clean all
else
  echo "$OS_ID detected — repos are active, no vault redirect needed"
fi
dnf makecache --refresh || true

# -----------------------------------------------------------------------------
# 2. Set hostname
# -----------------------------------------------------------------------------
echo "--- Setting hostname ---"
hostnamectl set-hostname headnode
echo "127.0.0.1 headnode" >> /etc/hosts
# Compute node entries — all nodes need to resolve each other by short name
%{ for i in range(compute_node_count) ~}
echo "${cidrhost(onprem_cidr, i + 10)} compute0${i + 1}" >> /etc/hosts
%{ endfor ~}

# -----------------------------------------------------------------------------
# 3. Configure iptables NAT (head node as cluster gateway)
# -----------------------------------------------------------------------------
echo "--- Configuring NAT ---"
# Rocky Linux 8 does not install iptables by default (uses nftables).
# Install iptables and iptables-services so we can persist NAT rules.
# The head node has direct internet access via its EIP before this step.
dnf install -y iptables iptables-services

# Enable IP forwarding persistently
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-burstlab-forward.conf
sysctl -p /etc/sysctl.d/99-burstlab-forward.conf

# Flush iptables-services default rules (which include a REJECT catch-all that
# breaks NAT and eventually exhausts conntrack, dropping new SSH connections).
# We set all default policies to ACCEPT and only add the MASQUERADE rule needed.
iptables -F
iptables -F -t nat
iptables -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Masquerade outbound traffic from cluster subnets through the EIP interface.
# The head node is the single internet gateway for all on-prem and cloud nodes.
ETH=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
iptables -t nat -A POSTROUTING -s ${onprem_cidr} -o "$ETH" -j MASQUERADE
iptables -t nat -A POSTROUTING -s ${cloud_cidr_a} -o "$ETH" -j MASQUERADE
iptables -t nat -A POSTROUTING -s ${cloud_cidr_b} -o "$ETH" -j MASQUERADE

# Persist these rules so iptables-services restores them on every boot.
# This replaces the iptables-services default ruleset entirely.
service iptables save
systemctl enable iptables

# -----------------------------------------------------------------------------
# 4. Mount EFS
# -----------------------------------------------------------------------------
echo "--- Mounting EFS via NFSv4.1 ---"
# EFS is mounted using plain nfs4 (nfs-utils). No amazon-efs-utils needed on Rocky/CentOS.
# /u  — cluster user home directories (EFS). Rocky Linux's /home stays on LOCAL disk
#       so that SSH access for the rocky admin user never depends on EFS availability.
# /opt/slurm — Slurm binaries, configs, and plugin (EFS).
mkdir -p /u /opt/slurm

# /u — cluster user home directories. Mounted at /u, not /home, so the OS rocky user's
# home (/home/rocky, local disk, pre-created in AMI) is never shadowed by EFS.
# This is the standard HPC pattern (e.g. /u, /cluster/home) used at most universities.
# nofail: don't block boot if EFS is temporarily unavailable.
# x-systemd.requires/after=network-online.target: wait for DNS before systemd tries
# to start the mount unit, preventing the race condition where systemd picks up the
# new fstab entry mid-boot before DNS is resolvable.
echo "${efs_dns_name}:/ /u nfs4 _netdev,nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,nofail,x-systemd.requires=network-online.target,x-systemd.after=network-online.target 0 0" >> /etc/fstab

# /opt/slurm — Slurm binaries, configs, and plugin shared across all nodes
echo "${efs_dns_name}:/slurm /opt/slurm nfs4 _netdev,nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,nofail,x-systemd.requires=network-online.target,x-systemd.after=network-online.target 0 0" >> /etc/fstab

# Bootstrap: create EFS /slurm subdirectory if it doesn't exist.
# NFSv4 subpath mounts require the directory to exist on the server first.
# Mount EFS root temporarily, create /slurm, then unmount before fstab mounts.
mkdir -p /mnt/efs-bootstrap
_EFS_BOOTSTRAP_MOUNTED=0
for attempt in 1 2 3 4 5; do
  mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport \
    "${efs_dns_name}:/" /mnt/efs-bootstrap && { _EFS_BOOTSTRAP_MOUNTED=1; break; } || {
    echo "EFS bootstrap mount attempt $attempt failed, retrying in 10s..."
    sleep 10
  }
done
if [ "$_EFS_BOOTSTRAP_MOUNTED" = "1" ]; then
  mkdir -p /mnt/efs-bootstrap/slurm
  mkdir -p /mnt/efs-bootstrap/alice
  umount /mnt/efs-bootstrap
  echo "EFS /slurm and /alice directories ensured."
else
  echo "WARN: EFS bootstrap mount failed — /slurm subpath mount may fail."
fi
rmdir /mnt/efs-bootstrap 2>/dev/null || true

# Mount EFS — retry loop because EFS mount target may not be ready immediately
for dir in /u /opt/slurm; do
  for attempt in 1 2 3 4 5; do
    mount "$dir" && break || {
      echo "EFS mount attempt $attempt for $dir failed, retrying in 10s..."
      sleep 10
    }
  done
done

# Inject the EC2 key pair's public key into rocky's authorized_keys on LOCAL disk.
# rocky's home (/home/rocky) is local to the head node — no EFS dependency.
# This means SSH always works regardless of EFS state, which is the whole point
# of mounting cluster user homes at /u instead of /home.
_IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300" || true)
_EC2_PUBKEY=$(curl -sf -H "X-aws-ec2-metadata-token: $_IMDS_TOKEN" \
  "http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key" || true)
if [ -n "$_EC2_PUBKEY" ]; then
  mkdir -p /home/rocky/.ssh
  grep -qF "$_EC2_PUBKEY" /home/rocky/.ssh/authorized_keys 2>/dev/null || echo "$_EC2_PUBKEY" >> /home/rocky/.ssh/authorized_keys
  chown rocky:rocky /home/rocky/.ssh/authorized_keys
  chmod 700 /home/rocky/.ssh
  chmod 600 /home/rocky/.ssh/authorized_keys
  echo "SSH key injected to local /home/rocky/.ssh/authorized_keys."
fi

# Set up alice's home directory on EFS (/u/home/alice).
# alice is the cluster demo user (UID 2000, created in AMI).
# Her home is on EFS so it's accessible from all nodes — head, compute, burst.
if mountpoint -q /u; then
  mkdir -p /u/home/alice
  # chown only if alice user exists in this AMI (she's added in the updated AMI build)
  getent passwd alice >/dev/null 2>&1 && chown alice:alice /u/home/alice || true
  chmod 700 /u/home/alice
  echo "Created /u/home/alice home directory on EFS."
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
  touch /opt/slurm/.burstlab-populated
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

# -----------------------------------------------------------------------------
# 6. Configure munge
# -----------------------------------------------------------------------------
echo "--- Configuring munge ---"
# Write the munge key (generated by Terraform, base64 encoded)
echo "${munge_key_b64}" | base64 -d > /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 0400 /etc/munge/munge.key

# Also store on EFS so compute/burst nodes can copy it
cp /etc/munge/munge.key /opt/slurm/etc/munge/munge.key
chmod 0400 /opt/slurm/etc/munge/munge.key

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
sleep 5  # Give slurmdbd time to initialize the DB schema

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
/opt/slurm/bin/sacctmgr -i add user root account=default || true
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
python3 generate_conf.py

# Append only NodeName/PartitionName lines from slurm.conf.aws to slurm.conf.
# generate_conf.py also outputs plugin directives (PrivateData, ResumeProgram, etc.)
# which are already in the base slurm.conf template — appending them again causes
# "specified more than once" fatal errors. We extract only the node/partition lines.
if [ -f slurm.conf.aws ]; then
  echo "slurm.conf.aws generated:"
  cat slurm.conf.aws
  grep -E "^(NodeName|PartitionName)=" slurm.conf.aws >> /opt/slurm/etc/slurm.conf
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
# Must run as slurm user (owns the slurmctld socket).
# Use || true: crontab -u slurm may fail on distros that restrict cron access
# for nologin users via PAM/cron.allow. The cluster still works without it;
# burst nodes will just need manual state management if change_state.py isn't running.
# Note: `crontab -l` exits 1 when no crontab exists. With set -e inside the
# subshell, that would exit before the echo runs, piping empty stdin and clearing
# the crontab instead of adding to it. The `|| true` prevents that early exit.
(crontab -u slurm -l 2>/dev/null || true; echo "* * * * * /opt/slurm/etc/aws/change_state.py >> /var/log/slurm/change_state.log 2>&1") | crontab -u slurm - || \
  echo "[WARN] crontab install for slurm user failed — change_state.py cron not active"

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo "=== BurstLab head node init complete: $(date) ==="
echo ""
echo "Cluster status:"
/opt/slurm/bin/sinfo || true
