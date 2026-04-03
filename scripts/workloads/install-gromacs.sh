#!/bin/bash
# =============================================================================
# install-gromacs.sh — Install GROMACS via Spack AWS binary cache
#
# Installs GROMACS with single-node MPI support using Spack's binary cache.
# GROMACS lands in /opt/slurm/spack/opt/ on EFS and is available to all nodes.
#
# Single-node MPI is valid and common for computational chemistry simulations —
# mpirun -np 8 gmx_mpi mdrun runs across cores on one burst node.
# Multi-node MPI is not supported by the AWS Plugin for Slurm v2.
#
# Usage (run as root on head node):
#   sudo bash /opt/slurm/etc/workloads/install-gromacs.sh
#
# Called by: terraform/workloads/scenario1-compute/main.tf via null_resource SSH
# =============================================================================

set -euo pipefail
exec > >(tee /var/log/burstlab-gromacs-install.log) 2>&1
echo "=== BurstLab: installing GROMACS: $(date) ==="

SPACK_ROOT="/opt/slurm/spack"
GROMACS_SENTINEL="${SPACK_ROOT}/.burstlab-gromacs-ready"

if [ -f "$GROMACS_SENTINEL" ]; then
  echo "GROMACS already installed (sentinel exists). Skipping."
  exit 0
fi

if [ ! -f "${SPACK_ROOT}/.burstlab-spack-ready" ]; then
  echo "ERROR: Spack not installed. Run install-spack.sh first."
  exit 1
fi

source "${SPACK_ROOT}/share/spack/setup-env.sh"

# -----------------------------------------------------------------------------
# Install GROMACS from the AWS Spack binary cache
#
# Spec: gromacs@2024.1 %gcc +mpi
#   +mpi  — build with MPI support for single-node mpirun -np N usage
#   %gcc  — use system GCC (avoids needing a Spack-installed compiler)
#
# The AWS binary cache covers gromacs@2024.1 with common specs.
# If a binary is not available, Spack will fall back to source build.
# -----------------------------------------------------------------------------
echo "Installing GROMACS via Spack (binary cache first)..."
spack install --use-cache gromacs@2024.1 %gcc +mpi

# Generate Lmod modulefiles for GROMACS
echo "Generating Lmod modulefiles..."
spack module lmod refresh --delete-tree -y gromacs

# Create demo input data directory
DEMO_DATA="/opt/slurm/etc/workloads/data"
mkdir -p "${DEMO_DATA}"

# Create a minimal GROMACS benchmark input using GROMACS topology files.
# This uses the spc_water_box example which ships with GROMACS.
GMXBIN=$(spack location -i gromacs)/bin
if [ -d "$GMXBIN" ]; then
  # Generate a small water box for demo jobs
  GMX="${GMXBIN}/gmx"
  if [ -f "${GMX}" ]; then
    echo "Generating demo water box input..."
    cd "${DEMO_DATA}"
    # Create 1000-molecule SPC water box (tiny, ~seconds to run 100 steps)
    ${GMX} solvate -cs spc216.gro -o water-demo.gro -p topol.top 2>/dev/null || true
    # If direct generation fails, create a placeholder that the demo job handles
    echo "water-box-demo" > demo-ready.txt
  fi
fi

touch "$GROMACS_SENTINEL"

echo ""
echo "=== GROMACS installed: $(date) ==="
spack find gromacs
echo ""
echo "To use GROMACS:"
echo "  source /etc/profile.d/spack.sh"
echo "  module avail"
echo "  module load gromacs"
echo "  gmx_mpi --version"
