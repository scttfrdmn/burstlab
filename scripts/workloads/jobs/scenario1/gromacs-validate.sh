#!/bin/bash
# =============================================================================
# scenario1/gromacs-validate.sh — Quick GROMACS smoke test
#
# Runs a short GROMACS simulation (100 steps) to confirm Spack, Lmod, and
# the GROMACS installation are all working correctly on burst nodes.
#
# Usage:
#   sbatch /opt/slurm/etc/workloads/jobs/scenario1/gromacs-validate.sh
#
# Expected runtime: ~2 minutes on m7a.2xlarge
# =============================================================================

#SBATCH --job-name=gromacs-validate
#SBATCH --partition=aws
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --time=00:15:00
#SBATCH --output=/u/home/alice/logs/gromacs-validate-%j.out
#SBATCH --error=/u/home/alice/logs/gromacs-validate-%j.err

set -euo pipefail
mkdir -p /u/home/alice/logs

echo "=== GROMACS Validate: started on $(hostname): $(date) ==="
echo "Job ID: ${SLURM_JOB_ID}"
echo "Node: ${SLURMD_NODENAME}"

# Load Spack environment
if [ -f /opt/slurm/spack/share/spack/setup-env.sh ]; then
  source /opt/slurm/spack/share/spack/setup-env.sh
else
  echo "ERROR: Spack not found at /opt/slurm/spack/" >&2
  exit 1
fi

# Load GROMACS module
module load gromacs 2>/dev/null || {
  # Fall back to direct spack load if Lmod module not generated yet
  spack load gromacs
}

# Verify GROMACS is available
GMX=$(which gmx_mpi 2>/dev/null || which gmx 2>/dev/null)
echo "GROMACS binary: ${GMX}"
${GMX} --version | head -5

# Create working directory
WORKDIR="/u/home/alice/gromacs-validate-${SLURM_JOB_ID}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# Generate a simple water box using GROMACS built-in topology
# This avoids downloading any external data
echo "Generating test system..."
${GMX} solvate \
  -cs spc216.gro \
  -o water-box.gro \
  -p topol.top \
  -box 2.0 2.0 2.0 2>/dev/null

# Create minimal .mdp file (100 steps, no output files)
cat > validate.mdp << 'MDP'
integrator  = md
nsteps      = 100
dt          = 0.002
nstxout     = 0
nstvout     = 0
nstenergy   = 100
nstlog      = 100
coulombtype = PME
rcoulomb    = 1.2
rvdw        = 1.2
pbc         = xyz
MDP

# Preprocess
${GMX} grompp \
  -f validate.mdp \
  -c water-box.gro \
  -p topol.top \
  -o validate.tpr \
  -maxwarn 5 2>/dev/null

# Run the simulation — single-node MPI across SLURM_NTASKS cores
echo "Running GROMACS (100 steps, ${SLURM_NTASKS} MPI ranks)..."
mpirun -np ${SLURM_NTASKS} ${GMX} mdrun \
  -s validate.tpr \
  -deffnm validate \
  -ntmpi 1 \
  -ntomp ${SLURM_NTASKS} \
  -v 2>&1 | tail -20

echo ""
echo "=== GROMACS validation PASSED ==="
echo "  Node: $(hostname)"
echo "  GROMACS: $(${GMX} --version | grep 'GROMACS version')"
echo "  Cores used: ${SLURM_NTASKS}"
echo "  Completed: $(date)"

# Cleanup working directory
cd /u/home/alice
rm -rf "${WORKDIR}"
