# BurstLab Workloads Track

The workloads overlay demonstrates how HPC applications consume and produce data
in a cloud bursting environment. It builds on top of any existing BurstLab
generation cluster without touching the **core Terraform state or base
infrastructure**. (Some approaches do add to the running cluster — the wrapper
installs commands onto shared EFS, and prolog/epilog patches `slurm.conf` and
reconfigures Slurm — but these are additive overlays layered on the deployed
cluster, not changes to the base generation's Terraform.)

## Quick Start

```bash
# 1. Deploy the base workloads layer (once per cluster)
cd "$BURSTLAB_ROOT/terraform/workloads/base/"
cp terraform.tfvars.example terraform.tfvars
# Edit: gen_state_path, key_path
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/base" init
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/base" apply   # ~10 min (installs transfer tools)

# 2. Deploy the scenario you want to demo (example: Scenario 4 chain)
cd "$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx/"
cp terraform.tfvars.example terraform.tfvars
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx" init
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx" apply   # ~30 sec (IAM + S3 bucket)

# 3. SSH as alice and run the demo
ssh -i "$SSH_KEY" alice@<head_node_public_ip>
bash /opt/slurm/etc/workloads/jobs/scenario4/submit-chain.sh

# 4. Optional: deploy a transparent lifecycle approach on top
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-wrapper" init
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-wrapper" apply
# Then: fsx-sbatch /opt/slurm/etc/workloads/jobs/scenario4/wrapper/example-job.sh

# 5. Teardown
terraform destroy   # in scenario dir (and transparent approach dirs if applied), then in base/
# Core cluster is untouched
```

---

## Scenarios

| Scenario | Story | Key Tools | Storage |
|----------|-------|-----------|---------|
| [1 — Compute](scenario1-compute.md) | HPC application with no data staging | Spack, GROMACS, Lmod | EFS only |
| [2 — RODA](scenario2-roda.md) | Read public cloud datasets | s5cmd, rclone, Mountpoint | S3 read |
| [3 — Ephemeral EFS](scenario3-ephemeral-efs.md) | Job-scoped NFS scratch with three lifecycle approaches | AWS EFS API | EFS ephemeral |
| [4 — Ephemeral FSx](scenario4-ephemeral-fsx.md) | Job-scoped Lustre scratch linked to S3 with three lifecycle approaches | AWS FSx API | FSx + S3 |

Start with **Scenario 1** if the audience is new to cloud HPC. Go to **Scenario 3 or 4**
if they already understand burst mechanics and want to see cloud-native data management.

### Lifecycle Approaches (Scenarios 3 and 4)

Both ephemeral storage scenarios support four ways to trigger the storage lifecycle,
from most explicit to most transparent:

| Approach | Deployment | How to submit | Best for |
|----------|-----------|--------------|----------|
| **0 — Chain** | Built-in | `bash submit-chain.sh` | Teaching the mechanics step by step |
| **A — Wrapper** | `scenario{3,4}-wrapper/` | `fsx-sbatch myjob.sh` | Fastest to adopt; zero job script changes beyond installing the wrapper |
| **B — Prolog/Epilog** | `scenario{3,4}-prolog-epilog/` | `sbatch --comment=fsx:1200 myjob.sh` | Clusters that already use prolog/epilog for other things |
| **C — Burst Buffer** | `scenario4-burst-buffer/` | `sbatch myjob.sh` (with `#BB` directive) | FSx only; HPC centers familiar with DataWarp/Cray burst buffers |

See [transparent-lifecycle.md](transparent-lifecycle.md) for a full comparison with SA talking points.

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
├── scenario3-wrapper/       # efs-sbatch deploy (Approach A)
├── scenario3-prolog-epilog/ # EFS prolog/epilog + slurm.conf patch (Approach B)
├── scenario4-ephemeral-fsx/ # FSx + S3 policy, FSx service-linked role
├── scenario4-wrapper/       # fsx-sbatch deploy (Approach A)
├── scenario4-prolog-epilog/ # FSx prolog/epilog + slurm.conf patch (Approach B)
└── scenario4-burst-buffer/  # Lua burst buffer plugin + burstbuffer.conf (Approach C)
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
