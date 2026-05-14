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
#   6. Write munge key from Terraform-injected base64, start munge
#   7. Start slurmd with the correct node name
#
# Terraform templatefile() substitutions — see ALLCAPS vars replaced at deploy time.
# =============================================================================

set -euo pipefail
exec > >(tee /var/log/burstlab-init.log) 2>&1
echo "=== BurstLab compute node init started: $(date) ==="

# -----------------------------------------------------------------------------
# 1. Detect OS family and fix repos if needed
# -----------------------------------------------------------------------------
OS_ID=$(. /etc/os-release && echo "$ID")
OS_FAMILY="rhel"
if [ "$OS_ID" = "ubuntu" ] || [ "$OS_ID" = "debian" ]; then
  OS_FAMILY="debian"
fi

# Fix repos if needed (CentOS 8 only — Rocky 8 repos are active)
if [ "$OS_ID" = "centos" ]; then
  sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*.repo
  sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo
  dnf clean all
fi

# Ensure cluster users exist with pinned UID/GID (alice = demo HPC user)
getent group  alice >/dev/null 2>&1 || groupadd  -g 2000 alice
getent passwd alice >/dev/null 2>&1 || useradd -M -u 2000 -g alice -s /bin/bash -d /home/alice alice

# -----------------------------------------------------------------------------
# 1b. Pre-install Lustre client for FSx Lustre mounts (Scenario 4 workloads)
# Rocky 8/9: Use AWS FSx Lustre client repo (available for el8/el9).
# Rocky 10: Use burstlab-lustre GitHub release (AWS repo has no el10 packages).
# Ubuntu: Use burstlab-lustre GitHub release (AWS repo has no Ubuntu packages).
# -----------------------------------------------------------------------------
echo "--- Installing Lustre client ---"
if [ "$OS_FAMILY" = "rhel" ]; then
  OS_MAJOR=$(. /etc/os-release && echo "$${VERSION_ID%%.*}")
  if [ "$OS_MAJOR" = "10" ]; then
    # Rocky 10: Install from burstlab-lustre GitHub release
    echo "Installing Lustre 2.17.0 from burstlab-lustre (Rocky 10)..."
    cd /tmp
    curl -sLO https://github.com/scttfrdmn/burstlab-lustre/releases/download/v1.0.0/kmod-lustre-client-2.17.0-1.el10.x86_64.rpm
    curl -sLO https://github.com/scttfrdmn/burstlab-lustre/releases/download/v1.0.0/lustre-client-2.17.0-1.el10.x86_64.rpm
    dnf install -y ./kmod-lustre-client-*.rpm ./lustre-client-*.rpm && rm -f *.rpm
    modprobe lustre && echo "✅ Lustre 2.17.0 loaded successfully" || echo "⚠️  Lustre load deferred until after reboot"
  else
    # Rocky 8/9: Use AWS FSx Lustre repo
    cat > /etc/yum.repos.d/fsx-lustre-client.repo << REPOEOF
[aws-fsx]
name=AWS FSx Packages - x86_64
baseurl=https://fsx-lustre-client-repo.s3.amazonaws.com/el/$${OS_MAJOR}/x86_64/
enabled=1
gpgcheck=0
skip_if_unavailable=1
REPOEOF
    dnf install -y kmod-lustre-client lustre-client && echo "✅ Lustre client installed from AWS repo"
  fi
else
  # Ubuntu: Install from burstlab-lustre GitHub release
  . /etc/os-release
  if [ "$VERSION_ID" = "22.04" ]; then
    echo "Installing Lustre 2.17.53 from burstlab-lustre (Ubuntu 22.04)..."
    cd /tmp
    curl -sLO https://github.com/scttfrdmn/burstlab-lustre/releases/download/v1.0.0/lustre-client-modules-6.8.0-1053-aws_2.17.53-1_amd64.deb
    curl -sLO https://github.com/scttfrdmn/burstlab-lustre/releases/download/v1.0.0/lustre-client-utils-ubuntu2204_2.17.53-1_amd64.deb
    apt-get install -y ./*.deb && rm -f *.deb
    modprobe lustre && echo "✅ Lustre 2.17.53 loaded successfully" || echo "⚠️  Lustre load deferred until after reboot"
  elif [ "$VERSION_ID" = "24.04" ]; then
    echo "Installing Lustre 2.17.53 from burstlab-lustre (Ubuntu 24.04)..."
    cd /tmp
    curl -sLO https://github.com/scttfrdmn/burstlab-lustre/releases/download/v1.0.0/lustre-client-modules-6.17.0-1013-aws_2.17.53-1_amd64.deb
    curl -sLO https://github.com/scttfrdmn/burstlab-lustre/releases/download/v1.0.0/lustre-client-utils-ubuntu2404_2.17.53-1_amd64.deb
    apt-get install -y ./*.deb && rm -f *.deb
    modprobe lustre && echo "✅ Lustre 2.17.53 loaded successfully" || echo "⚠️  Lustre load deferred until after reboot"
  else
    echo "⚠️  Ubuntu $VERSION_ID not supported. FSx Lustre unavailable. EFS workloads unaffected."
  fi
fi

# Disable iptables-services (installed in AMI) — default rules have REJECT catch-all
# that blocks munge (873), slurmctld (6817), and NFS (2049).
systemctl stop iptables 2>/dev/null || true
systemctl disable iptables 2>/dev/null || true
iptables -F 2>/dev/null || true
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true

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
echo "${cidrhost(onprem_cidr, i + 10)} compute${format("%02d", i + 1)}" >> /etc/hosts
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
mkdir -p /opt/slurm

echo "${efs_dns_name}:/home /home nfs4 _netdev,nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,nofail,x-systemd.requires=network-online.target,x-systemd.after=network-online.target 0 0" >> /etc/fstab
echo "${efs_dns_name}:/slurm /opt/slurm nfs4 _netdev,nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,nofail,x-systemd.requires=network-online.target,x-systemd.after=network-online.target 0 0" >> /etc/fstab

# Retry mounting — EFS DNS propagation and head node init may still be running
for dir in /home /opt/slurm; do
  for attempt in $(seq 1 30); do
    mount "$dir" && break || {
      echo "EFS mount attempt $attempt/30 for $dir failed, retrying in 20s..."
      sleep 20
    }
  done
  mountpoint -q "$dir" || { echo "FATAL: could not mount $dir after 30 attempts"; exit 1; }
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
# Key is injected by Terraform as base64 in munge_key_b64 (same key on all nodes)
# -----------------------------------------------------------------------------
mkdir -p /var/log/slurm /var/spool/slurm/d
chown slurm:slurm /var/log/slurm /var/spool/slurm/d

# Write munge key directly from Terraform-injected base64 — no EFS dependency.
# This eliminates the race where the head node hasn't written the key to EFS yet.
echo "${munge_key_b64}" | base64 -d > /etc/munge/munge.key
chown munge:munge /etc/munge/munge.key
chmod 0400 /etc/munge/munge.key

systemctl enable munge
systemctl start munge
systemctl is-active munge || { echo "FATAL: munge failed"; exit 1; }

# Verify munge can reach the head node before starting slurmd
for attempt in 1 2 3 4 5; do
  munge -n | unmunge && break || {
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

# Set SLURM_CONF and PATH for interactive shells (SSH sessions, alice, etc.)
cat > /etc/profile.d/slurm.sh << 'SLURMPROFILE'
export SLURM_CONF=/opt/slurm/etc/slurm.conf
export PATH=/opt/slurm/bin:/opt/slurm/sbin:$PATH
SLURMPROFILE
chmod 644 /etc/profile.d/slurm.sh

echo "=== BurstLab compute node $NODE_NAME init complete: $(date) ==="
