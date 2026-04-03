#!/bin/bash
# =============================================================================
# install-spack.sh — Bootstrap Spack + Lmod on shared EFS
#
# Installs Spack and Lmod to /opt/slurm/spack/ on EFS. Because /opt/slurm is
# already mounted from EFS on every node (head, compute, burst), no launch
# template changes are needed — all nodes get Spack automatically.
#
# Uses the AWS Spack binary cache (s3://spack-binaries) so packages install
# in minutes rather than compiling from source.
#
# Usage (run as root on head node):
#   sudo bash /opt/slurm/etc/workloads/install-spack.sh
#
# Called by: terraform/workloads/scenario1-compute/main.tf via null_resource SSH
# =============================================================================

set -euo pipefail
exec > >(tee /var/log/burstlab-spack-install.log) 2>&1
echo "=== BurstLab: installing Spack + Lmod: $(date) ==="

SPACK_ROOT="/opt/slurm/spack"
MODULES_ROOT="/opt/slurm/modules"
SPACK_VERSION="v0.23.0"
SENTINEL="${SPACK_ROOT}/.burstlab-spack-ready"

# Skip if already installed
if [ -f "$SENTINEL" ]; then
  echo "Spack already installed (sentinel exists). Skipping."
  echo "To reinstall: rm $SENTINEL && re-run this script"
  exit 0
fi

# -----------------------------------------------------------------------------
# 1. Create EFS directories
# EFS is already mounted at /opt/slurm by the time this script runs.
# -----------------------------------------------------------------------------
mkdir -p "${SPACK_ROOT}" "${MODULES_ROOT}"
chmod 755 "${SPACK_ROOT}" "${MODULES_ROOT}"
echo "Directories created: ${SPACK_ROOT}, ${MODULES_ROOT}"

# -----------------------------------------------------------------------------
# 2. Install Lmod
# Lmod provides `module load/unload/avail`. Install via EPEL if available,
# fall back to direct install from GitHub releases.
# -----------------------------------------------------------------------------
if command -v module &>/dev/null; then
  echo "Lmod already available."
else
  echo "Installing Lmod..."
  # Try EPEL first (available on Rocky 8/9/10)
  dnf install -y epel-release 2>/dev/null || true
  dnf install -y Lmod 2>/dev/null && LMOD_INSTALLED=true || LMOD_INSTALLED=false

  if [ "$LMOD_INSTALLED" = "false" ]; then
    # Fallback: install Lua dependencies and Lmod from source
    echo "EPEL Lmod install failed — installing from source..."
    dnf install -y lua lua-devel lua-posix tcl 2>/dev/null || true

    LMOD_VERSION="8.7.37"
    curl -fsSL "https://github.com/TACC/Lmod/archive/refs/tags/${LMOD_VERSION}.tar.gz" \
      | tar xz -C /tmp
    cd "/tmp/Lmod-${LMOD_VERSION}"
    ./configure --prefix=/usr/share/lmod
    make install
    ln -sf /usr/share/lmod/lmod/init/profile /etc/profile.d/00-modulepath.sh
    cd /
    rm -rf "/tmp/Lmod-${LMOD_VERSION}"
  fi

  echo "Lmod installed: $(module --version 2>&1 | head -1 || echo 'present')"
fi

# -----------------------------------------------------------------------------
# 3. Clone Spack to EFS
# Using a pinned version for reproducibility.
# -----------------------------------------------------------------------------
if [ ! -d "${SPACK_ROOT}/.git" ]; then
  echo "Cloning Spack ${SPACK_VERSION} to ${SPACK_ROOT}..."
  git clone --depth 1 --branch "${SPACK_VERSION}" \
    https://github.com/spack/spack.git "${SPACK_ROOT}"
  echo "Spack cloned."
else
  echo "Spack already cloned at ${SPACK_ROOT}."
fi

source "${SPACK_ROOT}/share/spack/setup-env.sh"

# -----------------------------------------------------------------------------
# 4. Configure the AWS Spack binary cache
#
# AWS maintains a public Spack binary cache at s3://spack-binaries, served
# via the CloudFront CDN at https://binaries.spack.io. This provides pre-built
# binaries for common compilers and specs, avoiding source compilation.
#
# The cache is public (no credentials needed). Using the CDN URL is preferred
# as it routes to the nearest edge location.
# -----------------------------------------------------------------------------
echo "Configuring AWS Spack binary cache..."
spack mirror add --oci-username-variable SPACK_OCI_USERNAME \
  --oci-password-variable SPACK_OCI_PASSWORD \
  aws-cache https://binaries.spack.io/releases/${SPACK_VERSION} 2>/dev/null || \
spack mirror add aws-cache https://binaries.spack.io/releases/${SPACK_VERSION}

# Trust the GPG key for the binary cache
spack buildcache keys --install --trust --force

cat > "${SPACK_ROOT}/etc/spack/mirrors.yaml" << EOF
mirrors:
  aws-binaries:
    fetch:
      url: https://binaries.spack.io/releases/${SPACK_VERSION}
      access_pair: [null, null]
    push:
      url: https://binaries.spack.io/releases/${SPACK_VERSION}
EOF

# -----------------------------------------------------------------------------
# 5. Configure Lmod module paths to point to EFS
# All Spack-generated modulefiles land in ${MODULES_ROOT}.
# -----------------------------------------------------------------------------
cat > "${SPACK_ROOT}/etc/spack/modules.yaml" << 'EOF'
modules:
  default:
    roots:
      lmod: /opt/slurm/modules
    lmod:
      all:
        conflict:
          - '{name}'
      projections:
        all: '{name}/{version}'
      core_compilers:
        - 'gcc@system'
EOF

# -----------------------------------------------------------------------------
# 6. Global profile.d entry — visible to ALL nodes via EFS
# Both head node and burst nodes source /opt/slurm/etc/profile.d/spack.sh
# because /opt/slurm is mounted from EFS on every node.
# -----------------------------------------------------------------------------
mkdir -p /etc/profile.d
cat > /etc/profile.d/spack.sh << 'SPACKPROFILE'
# BurstLab Spack environment — auto-sourced on all cluster nodes
if [ -f /opt/slurm/spack/share/spack/setup-env.sh ]; then
  source /opt/slurm/spack/share/spack/setup-env.sh
  # Add Spack-generated Lmod modulefiles
  if command -v module &>/dev/null; then
    module use /opt/slurm/modules/linux-*/Core 2>/dev/null || true
  fi
fi
SPACKPROFILE
chmod 644 /etc/profile.d/spack.sh

# Sentinel file — prevents reinstall on subsequent runs
touch "$SENTINEL"

echo ""
echo "=== Spack + Lmod installed: $(date) ==="
echo "  Spack root:   ${SPACK_ROOT}"
echo "  Modules root: ${MODULES_ROOT}"
echo "  Version:      ${SPACK_VERSION}"
echo "  Binary cache: https://binaries.spack.io/releases/${SPACK_VERSION}"
echo ""
echo "Next: run install-gromacs.sh to install GROMACS, or:"
echo "  source /opt/slurm/spack/share/spack/setup-env.sh"
echo "  spack install --use-cache <package>"
