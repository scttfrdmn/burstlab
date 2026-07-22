# BurstLab Documentation

Start here. This page organizes the docs into a guided journey rather than a flat list.
If any capability claim in a specific doc disagrees with the
[**support matrix**](support-matrix.md), the matrix is authoritative.

## Choose your path

| I want to… | Read, in order |
|------------|----------------|
| **Deploy my first cluster** | [prerequisites](prerequisites.md) → [quickstart](quickstart.md) → [support matrix](support-matrix.md) |
| **Run an SA demo** | [sa-guide](sa-guide.md) → [quickstart](quickstart.md) → [slurm-intro](slurm-intro.md) |
| **Pick a Slurm generation** | [generations](generations.md) → [support matrix](support-matrix.md) |
| **Add data-staging workloads** | [workloads/overview](workloads/overview.md) → the scenario you need → [transparent-lifecycle](workloads/transparent-lifecycle.md) |
| **Understand cloud bursting** | [slurm-intro](slurm-intro.md) → [architecture](architecture.md) → [plugin-v2-setup](plugin-v2-setup.md) |
| **Deploy on Ubuntu** | [quickstart-ubuntu](quickstart-ubuntu.md) (only the deltas from the canonical flow) |

## Reference

- [**support-matrix.md**](support-matrix.md) — **single source of truth**: node counts, EFS/FSx, lifecycle, status per generation
- [prerequisites.md](prerequisites.md) — AWS quota, cost, security, pre-flight check
- [quickstart.md](quickstart.md) — canonical seven-step deploy (Gen 1)
- [generations.md](generations.md) — why five generations exist; how to choose
- [architecture.md](architecture.md) — network, EFS, NAT, IAM design
- [plugin-v2-setup.md](plugin-v2-setup.md) — the AWS Plugin for Slurm v2, file by file
- [slurm-intro.md](slurm-intro.md) — Slurm concepts and commands from zero
- Deep dives: [gen1](slurm-gen1-deep-dive.md) · [gen2](slurm-gen2-deep-dive.md) · [gen3](slurm-gen3-deep-dive.md)
- [roadmap.md](roadmap.md) — planned work and direction

## Workloads

- [overview.md](workloads/overview.md) — scenario selection and storage-tier matrix
- [scenario1-compute.md](workloads/scenario1-compute.md) — GROMACS + Spack (EFS only)
- [scenario2-roda.md](workloads/scenario2-roda.md) — RODA public datasets (S3 read)
- [scenario3-ephemeral-efs.md](workloads/scenario3-ephemeral-efs.md) — job-scoped EFS
- [scenario4-ephemeral-fsx.md](workloads/scenario4-ephemeral-fsx.md) — job-scoped FSx Lustre + S3
- [transparent-lifecycle.md](workloads/transparent-lifecycle.md) — chain vs wrapper vs prolog/epilog vs burst buffer
- [user-guide.md](workloads/user-guide.md) — for cluster users (after an admin enables a lifecycle)

## Conventions used throughout

- Commands assume you have cloned the repo and exported `BURSTLAB_ROOT`, `AWS_PROFILE`,
  `AWS_REGION`, and `SSH_KEY` as shown in the [quickstart](quickstart.md#before-you-start).
- Terraform commands use `-chdir="$BURSTLAB_ROOT/..."` so they work from any directory.
- Command blocks are labeled **local workstation** vs **head node (as alice)** wherever
  both appear — Terraform state lives only on your workstation, not on the cluster.
