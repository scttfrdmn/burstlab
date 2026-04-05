#!/bin/bash
# =============================================================================
# scenario1/gromacs-singlenode.sh — Full single-node MPI GROMACS simulation
#
# Demonstrates cloud bursting for computational chemistry:
# - Job submitted to the 'aws' partition — burst node launched on demand
# - GROMACS uses all vCPUs on the burst node via single-node MPI
# - Input data lives on shared EFS — no staging required
# - Results written to shared EFS — available on head node immediately
#
# SA talking point: "This is the simplest case — the data is small enough to
# live on EFS permanently. The customer submits a job, a burst node comes up,
# runs GROMACS with all 8 vCPUs, and the node powers down when done. Zero
# infrastructure work — just submit and wait."
#
# Usage:
#   sbatch /opt/slurm/etc/workloads/jobs/scenario1/gromacs-singlenode.sh
#
# Expected runtime: ~5 minutes on m7a.2xlarge (8 vCPU)
# =============================================================================

#SBATCH --job-name=gromacs-burst
#SBATCH --partition=aws
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --cpus-per-task=1
#SBATCH --mem=28G
#SBATCH --time=00:30:00
#SBATCH --output=/home/alice/logs/gromacs-burst-%j.out
#SBATCH --error=/home/alice/logs/gromacs-burst-%j.err

set -euo pipefail
mkdir -p /home/alice/logs /home/alice/results

echo "=== GROMACS Burst Demo: started: $(date) ==="
echo "  Job ID:    ${SLURM_JOB_ID}"
echo "  Node:      ${SLURMD_NODENAME:-$(hostname)}"
echo "  vCPUs:     ${SLURM_NTASKS}"

# Load Spack + GROMACS
source /opt/slurm/spack/share/spack/setup-env.sh
module load gromacs 2>/dev/null || spack load gromacs
GMX=$(which gmx_mpi 2>/dev/null || which gmx 2>/dev/null)

echo "  GROMACS:   $(${GMX} --version | grep 'GROMACS version' | awk '{print $NF}')"
echo ""

# Working directory on EFS
WORKDIR="/home/alice/gromacs-run-${SLURM_JOB_ID}"
RESULTS_DIR="/home/alice/results/gromacs-${SLURM_JOB_ID}"
mkdir -p "${WORKDIR}" "${RESULTS_DIR}"
cd "${WORKDIR}"

# Check for pre-generated demo input
DATA_DIR="/opt/slurm/etc/workloads/data"
if [ -f "${DATA_DIR}/water-demo.gro" ]; then
  echo "Using pre-generated demo input from ${DATA_DIR}"
  cp "${DATA_DIR}/water-demo.gro" system.gro
  cp "${DATA_DIR}/topol.top" . 2>/dev/null || true
else
  echo "Generating water box demo input..."
  ${GMX} solvate \
    -cs spc216.gro \
    -o system.gro \
    -p topol.top \
    -box 3.0 3.0 3.0 2>/dev/null
fi

# Production MD settings (1000 steps — demo-appropriate length)
cat > production.mdp << 'MDP'
integrator  = md
nsteps      = 1000
dt          = 0.002
nstxout     = 500
nstvout     = 0
nstenergy   = 100
nstlog      = 100
coulombtype = PME
rcoulomb    = 1.2
rvdw        = 1.2
pbc         = xyz
gen_vel     = yes
gen_temp    = 300
gen_seed    = 12345
MDP

# Preprocessing
echo "Preprocessing system..."
${GMX} grompp \
  -f production.mdp \
  -c system.gro \
  -p topol.top \
  -o production.tpr \
  -maxwarn 5 2>/dev/null

# Run — single-node MPI, all vCPUs
echo "Running GROMACS (1000 steps, ${SLURM_NTASKS} MPI ranks)..."
START_TIME=$(date +%s)

mpirun -np ${SLURM_NTASKS} ${GMX} mdrun \
  -s production.tpr \
  -deffnm production \
  -ntmpi 1 \
  -ntomp ${SLURM_NTASKS} \
  -v 2>&1

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Copy results to results directory
cp production.{log,edr,trr,gro} "${RESULTS_DIR}/" 2>/dev/null || true

echo ""
echo "=== GROMACS Burst Demo: COMPLETE ==="
echo "  Walltime:  ${ELAPSED}s"
echo "  Node:      ${SLURMD_NODENAME:-$(hostname)}"
echo "  Results:   ${RESULTS_DIR}/"
echo "  Files:     $(ls ${RESULTS_DIR}/ | tr '\n' ' ')"
echo "  Finished:  $(date)"
echo ""
echo "SA note: This burst node will power down after SuspendTime seconds."
echo "  Watch: sinfo -p aws"

# Cleanup working directory (keep results)
cd /home/alice
rm -rf "${WORKDIR}"
