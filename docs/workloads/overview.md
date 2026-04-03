# BurstLab Workloads Track

The workloads overlay demonstrates how HPC applications consume and produce data
in a cloud bursting environment. It builds on top of any existing BurstLab
generation cluster — the core cluster is never modified.

## Quick Start

```bash
# 1. Deploy the base workloads layer (once per cluster)
cd terraform/workloads/base/
cp terraform.tfvars.example terraform.tfvars
# Edit: gen_state_path, key_path
terraform init && terraform apply   # ~10 min (installs transfer tools)

# 2. Deploy the scenario you want to demo
cd terraform/workloads/scenario3-ephemeral-efs/
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply   # ~30 sec (IAM policies only)

# 3. SSH as alice and run the demo
ssh alice@<head_node_public_ip>
bash /opt/slurm/etc/workloads/jobs/scenario3/submit-chain.sh

# 4. Teardown
terraform destroy   # in scenario dir, then in base/
# Core cluster is untouched
```

---

## Scenarios

| Scenario | Story | Key Tools | Storage |
|----------|-------|-----------|---------|
| [1 — Compute](scenario1-compute.md) | HPC application with no data staging | Spack, GROMACS, Lmod | EFS only |
| [2 — RODA](scenario2-roda.md) | Read public cloud datasets | s5cmd, rclone, Mountpoint | S3 read |
| [3 — Ephemeral EFS](scenario3-ephemeral-efs.md) | Job-scoped NFS scratch, created and destroyed per job | AWS EFS API | EFS ephemeral |
| [4 — Ephemeral FSx](scenario4-ephemeral-fsx.md) | Job-scoped Lustre scratch linked to S3 | AWS FSx API | FSx + S3 |

Start with **Scenario 1** if the audience is new to cloud HPC. Go to **Scenario 3 or 4**
if they already understand burst mechanics and want to see cloud-native data management.

---

## Storage Tier Decision Matrix

```
On-prem NAS/Lustre
        │
        │  rsync / rclone / s5cmd / Globus
        ▼
      S3 (permanent)              ← $0.023/GB-month
        │
        │  AutoImportPolicy (FSx)
        │  or job-time mount (Mountpoint/s5cmd)
        ▼
  FSx Lustre scratch              ← $0.14/GB-month (min 1200 GB)
  or EFS scratch                  ← $0.30/GB-month
        │
        │  application reads/writes
        ▼
    Burst node /tmp               ← instance storage (free)
        │
        │  results written to FSx/EFS
        │  flushed to S3 on job end
        ▼
      S3 (permanent)              ← $0.023/GB-month
```

**Rule of thumb**: S3 is the only permanent store. EFS and FSx are ephemeral cache layers.
Use FSx for parallel I/O (many processes, large files). Use EFS when POSIX semantics matter
and I/O isn't the bottleneck. Use S3 directly via Mountpoint or s5cmd when files are read once.

---

## Transfer Tools

| Tool | Best For | Throughput | Integrity |
|------|----------|------------|-----------|
| rsync | On-prem NFS → EFS | moderate | checksum |
| s5cmd | Bulk S3 (fastest) | very high | no verify |
| rclone | S3 with integrity | high | checksum |
| Globus | Existing endpoints, compliance | high | checksum |
| Mountpoint | Read-once S3 as POSIX | streaming | no |

All tools are installed to the head node by `terraform/workloads/base/`.

---

## Overlay Architecture

The workloads overlay uses Terraform `terraform_remote_state` to read an existing
generation cluster's state without modifying it. Each scenario layer adds only
IAM policies scoped to that scenario, removed cleanly on `terraform destroy`.

```
terraform/workloads/
├── base/                    # S3 bucket, transfer tools, script deploy
├── scenario1-compute/       # Spack + GROMACS install
├── scenario2-roda/          # S3 read policy on burst role
├── scenario3-ephemeral-efs/ # EFS lifecycle policy on burst + head roles
└── scenario4-ephemeral-fsx/ # FSx + S3 policy, FSx service-linked role
```

Each scenario's Terraform layer is independent and can be applied/destroyed
without affecting other scenarios or the core cluster.

---

## Granularity Modes (Scenarios 3 and 4)

Ephemeral storage can be scoped to different lifetimes:

| Mode | State Key | Storage Lifetime | Use Case |
|------|-----------|-----------------|----------|
| `per-job` | `SLURM_JOB_ID` | One job submission | Independent jobs, different datasets |
| `per-array` | `SLURM_ARRAY_JOB_ID` | One array submission | Shared scratch across all array tasks |
| `per-campaign` | `CAMPAIGN_NAME` | Manual end | Named storage across multiple submissions |

```bash
# per-job (default)
bash submit-chain.sh

# per-array
bash submit-chain.sh --granularity per-array --array-tasks 0-7

# per-campaign (manual destroy)
bash submit-chain.sh --granularity per-campaign --campaign-name protein-sweep
# ...more jobs run against the same storage...
# End the campaign:
CAMPAIGN_NAME=protein-sweep bash job3-destroy-efs.sh
```
