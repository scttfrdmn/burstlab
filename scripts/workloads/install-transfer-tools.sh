#!/bin/bash
# =============================================================================
# install-transfer-tools.sh — Install data transfer tools on the head node
#
# Installs: rclone, s5cmd, AWS Mountpoint for S3
# rsync is already present on all Rocky Linux systems.
#
# Designed to be idempotent — re-running is safe. Tools are already installed
# when /opt/slurm/.burstlab-transfer-tools-ready exists.
#
# Usage (run as root on head node):
#   sudo bash /opt/slurm/etc/workloads/install-transfer-tools.sh [AWS_REGION]
#
# Called by: terraform/workloads/base/main.tf via null_resource SSH
# =============================================================================

set -euo pipefail
exec > >(tee /var/log/burstlab-transfer-tools.log) 2>&1
echo "=== BurstLab: installing transfer tools: $(date) ==="

AWS_REGION="${1:-us-west-2}"
ARCH=$(uname -m)   # x86_64 or aarch64
SENTINEL="/opt/slurm/.burstlab-transfer-tools-ready"

# Skip if already installed (idempotency)
if [ -f "$SENTINEL" ]; then
  echo "Transfer tools already installed (sentinel exists). Skipping."
  exit 0
fi

# -----------------------------------------------------------------------------
# 1. rclone — S3-native parallel transfers with integrity checking
# -----------------------------------------------------------------------------
if ! command -v rclone &>/dev/null; then
  echo "Installing rclone..."
  curl -fsSL https://rclone.org/install.sh | bash
  echo "rclone: $(rclone version | head -1)"
else
  echo "rclone already installed: $(rclone version | head -1)"
fi

# Configure rclone for AWS (uses instance profile — no credentials needed)
mkdir -p /root/.config/rclone
cat > /root/.config/rclone/rclone.conf << 'EOF'
[aws]
type = s3
provider = AWS
env_auth = true
region = us-west-2
acl = private
server_side_encryption = AES256
EOF
# Also configure for alice (the demo user)
mkdir -p /u/home/alice/.config/rclone
cp /root/.config/rclone/rclone.conf /u/home/alice/.config/rclone/rclone.conf
chown -R alice:alice /u/home/alice/.config 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. s5cmd — fastest S3 tool for parallel multipart transfers
# -----------------------------------------------------------------------------
S5CMD_VERSION="2.2.2"
if ! command -v s5cmd &>/dev/null; then
  echo "Installing s5cmd ${S5CMD_VERSION}..."
  if [ "$ARCH" = "x86_64" ]; then
    S5CMD_URL="https://github.com/peak/s5cmd/releases/download/v${S5CMD_VERSION}/s5cmd_${S5CMD_VERSION}_Linux-64bit.tar.gz"
  else
    S5CMD_URL="https://github.com/peak/s5cmd/releases/download/v${S5CMD_VERSION}/s5cmd_${S5CMD_VERSION}_Linux-arm64.tar.gz"
  fi
  curl -fsSL "$S5CMD_URL" | tar xz -C /usr/local/bin s5cmd
  chmod 755 /usr/local/bin/s5cmd
  echo "s5cmd: $(s5cmd version)"
else
  echo "s5cmd already installed: $(s5cmd version)"
fi

# -----------------------------------------------------------------------------
# 3. AWS Mountpoint for S3 — POSIX-style S3 access (used in Scenario 2)
# -----------------------------------------------------------------------------
if ! command -v mount-s3 &>/dev/null; then
  echo "Installing AWS Mountpoint for S3..."
  if [ "$ARCH" = "x86_64" ]; then
    MP_URL="https://s3.amazonaws.com/mountpoint-s3-release/latest/x86_64/mount-s3.rpm"
  else
    MP_URL="https://s3.amazonaws.com/mountpoint-s3-release/latest/aarch64/mount-s3.rpm"
  fi
  dnf install -y "$MP_URL" 2>/dev/null || {
    echo "RPM install failed, trying direct binary..."
    curl -fsSL "https://s3.amazonaws.com/mountpoint-s3-release/latest/${ARCH}/mount-s3" \
      -o /usr/local/bin/mount-s3
    chmod 755 /usr/local/bin/mount-s3
  }
  echo "Mountpoint: $(mount-s3 --version 2>/dev/null || echo 'installed')"
else
  echo "mount-s3 already installed: $(mount-s3 --version 2>/dev/null || echo 'present')"
fi

# -----------------------------------------------------------------------------
# 4. Globus CLI — optional, only if GLOBUS_CLIENT_ID is set
# -----------------------------------------------------------------------------
if [ -n "${GLOBUS_CLIENT_ID:-}" ]; then
  echo "Installing Globus CLI..."
  pip3 install globus-cli
  echo "Globus: $(globus version 2>/dev/null || echo 'installed')"
else
  echo "GLOBUS_CLIENT_ID not set — skipping Globus install."
  echo "To install later: pip3 install globus-cli"
fi

# Create FUSE group for Mountpoint (allows non-root FUSE mounts)
getent group fuse >/dev/null 2>&1 || groupadd fuse
usermod -aG fuse alice 2>/dev/null || true

# Sentinel file — prevents reinstall on subsequent terraform applies
touch "$SENTINEL"

echo ""
echo "=== Transfer tools installed: $(date) ==="
echo "  rsync:      $(rsync --version | head -1)"
echo "  rclone:     $(rclone version | head -1)"
echo "  s5cmd:      $(s5cmd version)"
echo "  mount-s3:   $(mount-s3 --version 2>/dev/null || echo 'present')"
