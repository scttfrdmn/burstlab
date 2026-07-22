# Scenario 1: Compute-Only (GROMACS + Spack)

Demonstrates a compute-bound HPC application with no data staging requirements.
GROMACS is installed via Spack from the AWS binary cache and runs on a single
burst node with single-node MPI.

**Best for**: Audiences new to cloud HPC who want to see Slurm + burst nodes
before adding the complexity of cloud storage.

---

## What It Shows

- Spack managing scientific software on shared EFS (visible to all nodes)
- Lmod environment modules (`module load gromacs`)
- MPI job on a single burst node (`mpirun -np N`)
- Results written to permanent cluster EFS (`/home/alice/results/`)

---

## Prerequisites

1. Core cluster deployed (gen1, gen2, or gen3)
2. Base workloads layer applied (`terraform/workloads/base/`)
3. Scenario 1 layer applied (`terraform/workloads/scenario1-compute/`)

---

## Terraform Deploy

```bash
cd "$BURSTLAB_ROOT/terraform/workloads/base/"
cp terraform.tfvars.example terraform.tfvars
# Edit: gen_state_path = "../../generations/gen1-slurm2205-rocky8/terraform.tfstate"
#       key_path = "~/.ssh/burstlab"
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/base" init
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/base" apply
# Installs Spack to /opt/slurm/spack/ on EFS (~5-10 min)

cd "$BURSTLAB_ROOT/terraform/workloads/scenario1-compute/"
cp terraform.tfvars.example terraform.tfvars
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario1-compute" init
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario1-compute" apply
# Installs GROMACS via Spack binary cache (~5-10 min)
```

The Spack and GROMACS installs are null_resource provisioners that run once
and are gated by sentinel files on EFS. Re-running `terraform apply` is a no-op
if the sentinel files exist.

---

## Demo Steps

```bash
ssh -i "$SSH_KEY" alice@<head_node_ip>

# Verify Spack and GROMACS are available
source /opt/slurm/spack/share/spack/setup-env.sh
module avail gromacs

# Quick smoke test (100 steps, ~2 min)
sbatch /opt/slurm/etc/workloads/jobs/scenario1/gromacs-validate.sh

# Watch the burst node spin up
watch -n 5 squeue

# Full single-node run (1000 steps)
sbatch /opt/slurm/etc/workloads/jobs/scenario1/gromacs-singlenode.sh

# Results
ls ~/results/gromacs-*/
```

---

## SA Talking Points

- "GROMACS is installed on EFS — every burst node sees the same filesystem,
  so there's no per-node software install. Scale to 50 nodes and the
  software is already there."

- "The AWS Spack binary cache means no compilation — we downloaded a
  pre-built binary. Spack normally takes hours to build GROMACS from source.
  The binary cache makes it a 5-minute install."

- "Single-node MPI is fully supported. Multi-node MPI requires a fabric
  (EFA) and network-aware Slurm plugin configuration — that's a separate
  conversation."

- "Results land on the cluster's permanent EFS at `/home/alice/results/`.
  That's the shared home directory, visible from every node and from on-prem
  if you mount the same EFS."

---

## Job Scripts

| Script | Description | Runtime |
|--------|-------------|---------|
| `gromacs-validate.sh` | 100-step smoke test | ~2 min |
| `gromacs-singlenode.sh` | 1000-step production run | ~5-15 min |

Both scripts use `mpirun -np N` with `-ntmpi 1 -ntomp N` (single MPI rank,
N OpenMP threads) — optimal for single-node MPI on GROMACS.

---

## Teardown

```bash
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario1-compute" destroy   # removes null_resource state; does NOT remove Spack from EFS

terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/base" destroy   # removes S3 bucket, IAM policies, null_resource state
```

Spack and GROMACS remain on EFS after teardown (they're files, not Terraform
resources). If you want to remove them: `rm -rf /opt/slurm/spack/` on the head node.
