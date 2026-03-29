#!/bin/bash
# =============================================================================
# burst-node-init.sh — BurstLab Gen 1 burst node cloud-init
#
# This script runs on EC2 instances launched by Plugin v2 (resume.py).
# The instance is named cloud-burst-N by resume.py (via EC2 Name tag).
# IMDS tag access (InstanceMetadataTags=enabled) is set in the launch template.
#
# What this script does:
#   1. Fix CentOS 8 EOL repos
#   2. Read SLURM_NODENAME from EC2 Name tag via IMDS
#   3. Set hostname to match Slurm node name
#   4. Add /etc/hosts entries for cluster nodes
#   5. Mount EFS: /home and /opt/slurm
#   6. Copy munge key from EFS, start munge
#   7. Start slurmd -N $SLURM_NODENAME
#
# Terraform templatefile() substitutions — see ALLCAPS vars replaced at deploy time.
# =============================================================================

set -euo pipefail
exec > >(tee /var/log/burstlab-init.log) 2>&1
echo "=== BurstLab burst node init started: $(date) ==="

# -----------------------------------------------------------------------------
# 1. Fix repos if needed (CentOS 8 only — Rocky 8 repos are active)
# -----------------------------------------------------------------------------
OS_ID=$(. /etc/os-release && echo "$ID")
if [ "$OS_ID" = "centos" ]; then
  sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*.repo
  sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo
  dnf clean all
fi

# Ensure cluster users exist with pinned UID/GID (alice = demo HPC user)
getent group  alice >/dev/null 2>&1 || groupadd  -g 2000 alice
getent passwd alice >/dev/null 2>&1 || useradd -u 2000 -g alice -s /bin/bash -d /u/home/alice alice

# -----------------------------------------------------------------------------
# 2. Read node name from EC2 Name tag
# InstanceMetadataTags=enabled is set in the launch template.
# resume.py sets the Name tag to cloud-burst-N before the instance starts.
# This is how slurmd knows what name to register under.
# -----------------------------------------------------------------------------
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")

for attempt in $(seq 1 10); do
  SLURM_NODENAME=$(curl -sf \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/tags/instance/Name") && break || {
    echo "IMDS tag read attempt $attempt failed, retrying in 5s..."
    sleep 5
  }
done

if [ -z "$SLURM_NODENAME" ]; then
  echo "FATAL: could not determine SLURM_NODENAME from EC2 Name tag"
  exit 1
fi
echo "SLURM_NODENAME: $SLURM_NODENAME"

# Export for slurmd systemd unit
echo "SLURM_NODENAME=$SLURM_NODENAME" > /etc/sysconfig/slurmd

# -----------------------------------------------------------------------------
# 3. Set hostname to match Slurm node name
# Slurm resolves node names via /etc/hosts. The name must match NodeName in
# slurm.conf exactly or slurmd will fail to register.
# -----------------------------------------------------------------------------
hostnamectl set-hostname "$SLURM_NODENAME"
echo "127.0.0.1 $SLURM_NODENAME" >> /etc/hosts

# -----------------------------------------------------------------------------
# 4. Add /etc/hosts entries for cluster nodes
# Burst nodes need to resolve headnode to reach slurmctld (port 6817).
# -----------------------------------------------------------------------------
echo "${head_node_ip} headnode" >> /etc/hosts

# -----------------------------------------------------------------------------
# 5. Mount EFS
# Burst nodes are in the cloud subnets, which have EFS mount targets.
# Route to head node (NAT) is handled by the VPC route table.
# -----------------------------------------------------------------------------
mkdir -p /u /opt/slurm

echo "${efs_dns_name}:/ /u nfs4 _netdev,nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,nofail,x-systemd.requires=network-online.target,x-systemd.after=network-online.target 0 0" >> /etc/fstab
echo "${efs_dns_name}:/slurm /opt/slurm nfs4 _netdev,nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,nofail,x-systemd.requires=network-online.target,x-systemd.after=network-online.target 0 0" >> /etc/fstab

for dir in /u /opt/slurm; do
  for attempt in $(seq 1 10); do
    mount "$dir" && break || {
      echo "EFS mount attempt $attempt for $dir failed, retrying in 10s..."
      sleep 10
    }
  done
  mountpoint -q "$dir" || { echo "FATAL: could not mount $dir"; exit 1; }
done

# Wait for /opt/slurm to be populated (head node may still be initializing)
echo "Waiting for /opt/slurm/.burstlab-populated..."
for attempt in $(seq 1 20); do
  [ -f /opt/slurm/.burstlab-populated ] && break
  echo "Attempt $attempt: waiting 15s..."
  sleep 15
done
[ -f /opt/slurm/.burstlab-populated ] || { echo "FATAL: /opt/slurm never populated"; exit 1; }

# Create local spool dir (must NOT be on EFS — each node owns its own spool)
mkdir -p /var/spool/slurm/d /var/log/slurm
chown slurm:slurm /var/spool/slurm/d /var/log/slurm

# -----------------------------------------------------------------------------
# 6. Configure munge
# -----------------------------------------------------------------------------
cp /opt/slurm/etc/munge/munge.key /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 0400 /etc/munge/munge.key

systemctl enable munge
systemctl start munge
systemctl is-active munge || { echo "FATAL: munge failed"; exit 1; }

# Verify munge connectivity to head node
for attempt in $(seq 1 5); do
  munge -n | unmunge -s headnode && break || {
    echo "Munge connectivity attempt $attempt failed, retrying..."
    sleep 10
  }
done

# -----------------------------------------------------------------------------
# 7. Start slurmd
# The -N flag is critical — it tells slurmd to register as cloud-burst-N,
# which matches the NodeName= in slurm.conf that slurmctld is expecting.
# Without -N, slurmd uses the OS hostname, which may differ or not be in conf.
# -----------------------------------------------------------------------------

# Override the systemd unit to pass the correct node name
mkdir -p /etc/systemd/system/slurmd.service.d
cat > /etc/systemd/system/slurmd.service.d/nodename.conf << EOF
[Service]
EnvironmentFile=/etc/sysconfig/slurmd
ExecStart=
ExecStart=/opt/slurm/sbin/slurmd -N \$SLURM_NODENAME -D \$SLURMD_OPTIONS
EOF
systemctl daemon-reload

systemctl enable slurmd
systemctl start slurmd

sleep 3
systemctl is-active slurmd || {
  echo "FATAL: slurmd failed to start"
  journalctl -u slurmd --no-pager -n 30
  exit 1
}

echo "=== BurstLab burst node $SLURM_NODENAME init complete: $(date) ==="
