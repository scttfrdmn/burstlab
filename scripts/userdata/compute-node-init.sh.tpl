#!/bin/bash
# =============================================================================
# compute-node-init.sh — BurstLab Gen 1 compute node cloud-init
#
# What this script does:
#   1. Fix CentOS 8 EOL repos
#   2. Set hostname based on instance index (compute01, compute02, ...)
#   3. Add /etc/hosts entries for all cluster nodes
#   4. Configure default route via head node (NAT)
#   5. Mount EFS: /home and /opt/slurm
#   6. Copy munge key from EFS, start munge
#   7. Start slurmd with the correct node name
#
# Terraform templatefile() substitutions — see ALLCAPS vars replaced at deploy time.
# =============================================================================

set -euo pipefail
exec > >(tee /var/log/burstlab-init.log) 2>&1
echo "=== BurstLab compute node init started: $(date) ==="

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
# 2. Set hostname
# Terraform passes node_index (1-based) so compute01, compute02, etc.
# -----------------------------------------------------------------------------
NODE_NAME="compute$(printf '%02d' ${node_index})"
hostnamectl set-hostname "$NODE_NAME"
echo "127.0.0.1 $NODE_NAME" >> /etc/hosts

# -----------------------------------------------------------------------------
# 3. Add /etc/hosts entries for all cluster nodes
# Compute nodes need to resolve headnode and each other for munge/slurm.
# -----------------------------------------------------------------------------
echo "${head_node_ip} headnode" >> /etc/hosts
%{ for i in range(compute_node_count) ~}
echo "${cidrhost(onprem_cidr, i + 10)} compute0${i + 1}" >> /etc/hosts
%{ endfor ~}

# -----------------------------------------------------------------------------
# 4. Route internet traffic via head node (NAT instance)
# Compute nodes are in a private subnet with no direct IGW route.
# The route table already points 0.0.0.0/0 to the head node ENI, but we
# set it here explicitly for visibility and to handle DHCP edge cases.
# -----------------------------------------------------------------------------
ip route replace default via ${head_node_ip} 2>/dev/null || true

# -----------------------------------------------------------------------------
# 5. Mount EFS
# Wait for head node to have populated /opt/slurm before mounting.
# -----------------------------------------------------------------------------
mkdir -p /u /opt/slurm

echo "${efs_dns_name}:/ /u nfs4 _netdev,nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,nofail,x-systemd.requires=network-online.target,x-systemd.after=network-online.target 0 0" >> /etc/fstab
echo "${efs_dns_name}:/slurm /opt/slurm nfs4 _netdev,nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,nofail,x-systemd.requires=network-online.target,x-systemd.after=network-online.target 0 0" >> /etc/fstab

# Retry mounting — EFS and head node init may still be running
for dir in /u /opt/slurm; do
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    mount "$dir" && break || {
      echo "EFS mount attempt $attempt for $dir failed, retrying in 15s..."
      sleep 15
    }
  done
  mountpoint -q "$dir" || { echo "FATAL: could not mount $dir"; exit 1; }
done

# Wait for head node to finish populating EFS (poll for the sentinel file)
echo "Waiting for /opt/slurm to be populated by head node..."
for attempt in $(seq 1 20); do
  [ -f /opt/slurm/.burstlab-populated ] && break
  echo "Attempt $attempt: /opt/slurm not yet populated, waiting 15s..."
  sleep 15
done
[ -f /opt/slurm/.burstlab-populated ] || { echo "FATAL: /opt/slurm never populated"; exit 1; }

# -----------------------------------------------------------------------------
# 6. Configure munge
# Key lives on EFS at /opt/slurm/etc/munge/munge.key (written by head node)
# -----------------------------------------------------------------------------
mkdir -p /var/log/slurm /var/spool/slurm/d
chown slurm:slurm /var/log/slurm /var/spool/slurm/d

cp /opt/slurm/etc/munge/munge.key /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 0400 /etc/munge/munge.key

systemctl enable munge
systemctl start munge
systemctl is-active munge || { echo "FATAL: munge failed"; exit 1; }

# Verify munge can reach the head node before starting slurmd
for attempt in 1 2 3 4 5; do
  munge -n | unmunge -s headnode && break || {
    echo "Munge connectivity attempt $attempt failed, retrying in 10s..."
    sleep 10
  }
done

# -----------------------------------------------------------------------------
# 7. Start slurmd
# slurm.conf is read from /opt/slurm/etc/slurm.conf (on EFS).
# The -N flag sets the node name explicitly — must match slurm.conf NodeName.
# -----------------------------------------------------------------------------
systemctl enable slurmd
systemctl start slurmd

sleep 3
systemctl is-active slurmd || {
  echo "FATAL: slurmd failed to start"
  journalctl -u slurmd --no-pager -n 30
  exit 1
}

echo "=== BurstLab compute node $NODE_NAME init complete: $(date) ==="
