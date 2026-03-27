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
# Variables in %{ } are Terraform templatefile() substitutions.
# =============================================================================

set -euo pipefail
exec > >(tee /var/log/burstlab-init.log) 2>&1
echo "=== BurstLab head node init started: $(date) ==="

# -----------------------------------------------------------------------------
# 1. Fix CentOS 8 EOL repos
# -----------------------------------------------------------------------------
echo "--- Fixing CentOS 8 EOL repos ---"
sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*.repo
sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo
dnf clean all
# EPEL is already installed in the AMI; ensure it points to vault too
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
# Enable IP forwarding persistently
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-burstlab-forward.conf
sysctl -p /etc/sysctl.d/99-burstlab-forward.conf

# Masquerade traffic from on-prem and cloud subnets through eth0 (internet)
# eth0 is the primary interface with the EIP on CentOS 8
ETH=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
iptables -t nat -A POSTROUTING -s ${onprem_cidr} -o "$ETH" -j MASQUERADE
iptables -t nat -A POSTROUTING -s ${cloud_cidr_a} -o "$ETH" -j MASQUERADE
iptables -t nat -A POSTROUTING -s ${cloud_cidr_b} -o "$ETH" -j MASQUERADE
iptables -A FORWARD -i "$ETH" -o eth1 -m state --state RELATED,ESTABLISHED -j ACCEPT || true
iptables -A FORWARD -i eth1 -o "$ETH" -j ACCEPT || true

# Persist iptables rules
service iptables save || iptables-save > /etc/iptables/rules.v4 || true
# Make it survive reboots via rc.local
cat > /etc/rc.d/rc.local << 'RCEOF'
#!/bin/bash
ETH=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
iptables -t nat -A POSTROUTING -s ${onprem_cidr} -o "$ETH" -j MASQUERADE
iptables -t nat -A POSTROUTING -s ${cloud_cidr_a} -o "$ETH" -j MASQUERADE
iptables -t nat -A POSTROUTING -s ${cloud_cidr_b} -o "$ETH" -j MASQUERADE
sysctl -w net.ipv4.ip_forward=1
RCEOF
chmod +x /etc/rc.d/rc.local
systemctl enable rc-local

# -----------------------------------------------------------------------------
# 4. Mount EFS
# -----------------------------------------------------------------------------
echo "--- Mounting EFS ---"
# amazon-efs-utils is pre-installed in the AMI
mkdir -p /home /opt/slurm

# /home — user home directories shared across all nodes
echo "${efs_dns_name}:/ /home efs _netdev,tls,noresvport 0 0" >> /etc/fstab

# /opt/slurm — Slurm binaries, configs, and plugin shared across all nodes
echo "${efs_dns_name}:/slurm /opt/slurm efs _netdev,tls,noresvport 0 0" >> /etc/fstab

# Mount EFS — retry loop because EFS mount target may not be ready immediately
for dir in /home /opt/slurm; do
  for attempt in 1 2 3 4 5; do
    mount "$dir" && break || {
      echo "EFS mount attempt $attempt for $dir failed, retrying in 10s..."
      sleep 10
    }
  done
done

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
systemctl start slurmctld
sleep 3

systemctl is-active slurmdbd || { echo "FATAL: slurmdbd failed"; journalctl -u slurmdbd --no-pager -n 30; exit 1; }
systemctl is-active slurmctld || { echo "FATAL: slurmctld failed"; journalctl -u slurmctld --no-pager -n 30; exit 1; }

# Create the default Slurm account (required for job submission)
/opt/slurm/bin/sacctmgr -i add cluster ${cluster_name} || true
/opt/slurm/bin/sacctmgr -i add account default description="Default account" organization="BurstLab" || true
/opt/slurm/bin/sacctmgr -i add user root account=default || true

# -----------------------------------------------------------------------------
# 10. Install Plugin v2
# -----------------------------------------------------------------------------
echo "--- Installing AWS Plugin for Slurm v2 ---"
cd /opt/slurm/etc/aws
git clone --branch plugin-v2 --depth 1 \
  https://github.com/aws-samples/aws-plugin-for-slurm.git .

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

# Append the generated cloud node definitions to slurm.conf
if [ -f slurm.conf.aws ]; then
  # Remove the placeholder line and append actual generated config
  grep -v '^\$\{burst_node_conf\}' /opt/slurm/etc/slurm.conf > /tmp/slurm.conf.clean
  cat /tmp/slurm.conf.clean slurm.conf.aws > /opt/slurm/etc/slurm.conf
  echo "Appended burst node config to slurm.conf:"
  cat slurm.conf.aws
fi

# Copy gres.conf if generated (needed even if empty)
[ -f gres.conf.aws ] && cp gres.conf.aws /opt/slurm/etc/gres.conf || touch /opt/slurm/etc/gres.conf

# Reload slurmctld to pick up the new node/partition definitions
sleep 2
/opt/slurm/bin/scontrol reconfigure

# -----------------------------------------------------------------------------
# 12. Install change_state.py cron
# -----------------------------------------------------------------------------
echo "--- Installing change_state.py cron ---"
# Must run as slurm user (owns the slurmctld socket)
(crontab -u slurm -l 2>/dev/null; echo "* * * * * /opt/slurm/etc/aws/change_state.py >> /var/log/slurm/change_state.log 2>&1") | crontab -u slurm -

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo "=== BurstLab head node init complete: $(date) ==="
echo ""
echo "Cluster status:"
/opt/slurm/bin/sinfo
