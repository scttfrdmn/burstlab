# Scenario 3: Ephemeral EFS

Demonstrates job-scoped NFS storage: a Slurm job chain where Job 1 creates
an EFS filesystem, Job 2 mounts it and runs the workload, and Job 3 destroys it.
The filesystem exists only for the duration of the workload.

**Best for**: Audiences from environments with shared NFS scratch (Lustre, GPFS,
Isilon) who want a minimal-change path to cloud-native storage.

---

## What It Shows

- AWS EFS API called directly from a burst node (no pre-provisioned storage)
- Three-job Slurm dependency chain: create → compute → destroy
- Handoff via state file on permanent cluster EFS
- Three granularity modes: per-job, per-array, per-campaign
- Cost appears only during Job 2 execution

---

## Prerequisites

1. Core cluster deployed
2. Base workloads layer applied (`terraform/workloads/base/`)
3. Scenario 3 layer applied (`terraform/workloads/scenario3-ephemeral-efs/`)

---

## Terraform Deploy

```bash
cd terraform/workloads/base/
terraform init && terraform apply   # if not already done

cd terraform/workloads/scenario3-ephemeral-efs/
cp terraform.tfvars.example terraform.tfvars
# Edit: gen_state_path, cluster_name (must match the generation cluster)
terraform init && terraform apply
# Grants EFS lifecycle permissions to burst + head node IAM roles
```

After apply, get the subnet and security group IDs needed by the submit script:

```bash
terraform output cloud_subnet_a_id
terraform output efs_sg_id
```

---

## Demo Steps

```bash
ssh alice@<head_node_ip>

# Get required variables from Terraform output
CLOUD_SUBNET_A_ID=$(cd terraform/workloads/scenario3-ephemeral-efs/ && terraform output -raw cloud_subnet_a_id)
EFS_SG_ID=$(cd terraform/workloads/scenario3-ephemeral-efs/ && terraform output -raw efs_sg_id)

# Submit the three-job chain
CLOUD_SUBNET_A_ID=$CLOUD_SUBNET_A_ID \
EFS_SG_ID=$EFS_SG_ID \
AWS_REGION=us-west-2 \
  bash /opt/slurm/etc/workloads/jobs/scenario3/submit-chain.sh

# Watch all three jobs + the EFS lifecycle
watch -n 5 'squeue && echo && aws efs describe-file-systems \
  --query "FileSystems[].[FileSystemId,LifeCycleState,NumberOfMountTargets]" \
  --output table'
```

The EFS filesystem should appear in the AWS console during Job 2 and disappear
after Job 3 completes.

---

## Granularity Modes

### per-job (default)

Each `submit-chain.sh` invocation creates a new EFS volume with its own state
file keyed by `SLURM_JOB_ID`. Independent jobs cannot share the storage.

```bash
bash submit-chain.sh   # uses SLURM_JOB_ID as state key
```

### per-array

One EFS volume shared by all tasks in an array job. All tasks mount the same
filesystem and write to isolated subdirectories (`input/$SLURM_ARRAY_TASK_ID/`).

```bash
bash submit-chain.sh --granularity per-array --array-tasks 0-7
```

### per-campaign

Named EFS volume shared across multiple job submissions. Persists until manually
destroyed. Useful for demonstrating storage that outlives individual jobs.

```bash
# Start campaign
bash submit-chain.sh --granularity per-campaign --campaign-name protein-sweep

# More jobs against the same storage
GRANULARITY=per-campaign CAMPAIGN_NAME=protein-sweep \
  sbatch jobs/scenario3/job2-run-workload.sh

# End campaign (submit destroy manually)
CAMPAIGN_NAME=protein-sweep AWS_REGION=us-west-2 EFS_SG_ID=$EFS_SG_ID \
  sbatch jobs/scenario3/job3-destroy-efs.sh
```

---

## Timing

| Phase | Duration |
|-------|----------|
| EFS create to `available` | ~30-60 seconds |
| Mount target creation | ~30 seconds |
| Job 1 total (with polling) | ~2-3 minutes |
| Job 2 (demo workload) | ~1-2 minutes |
| Job 3 (destroy) | ~1-2 minutes |
| Total chain | ~5-7 minutes |

---

## State File

Job 1 writes a state file to `/u/home/alice/.efs-state/{key}.env` on permanent
cluster EFS. Job 2 sources this file to get the EFS ID. Job 3 sources it, destroys
the filesystem, and removes the file.

```bash
# Inspect the state file during Job 2
cat ~/.efs-state/<SLURM_JOB_ID>.env
# EFS_ID=fs-0123456789abcdef0
# EFS_MT_ID=fsmt-0123456789abcdef0
# EFS_DNS=fs-0123456789abcdef0.efs.us-west-2.amazonaws.com
# CREATED_BY_JOB=12345
# GRANULARITY=per-job
```

---

## SA Talking Points

- "Job 1 calls `aws efs create-file-system` directly from the burst node. There
  is no pre-provisioned storage pool, no ticket to your storage team, no waiting
  for capacity. The filesystem exists in about 60 seconds."

- "The state file on permanent EFS is the handoff between jobs. It's just a
  shell variable file. Job 2 reads the EFS ID, mounts the filesystem, runs the
  workload, and unmounts. Job 3 destroys it."

- "Watch the EFS console while the chain runs. The filesystem appears, serves
  the workload, and disappears. You're charged only for the data stored while
  it exists — typically a few cents for a demo."

- "For an on-prem person, the idea that storage can appear and disappear with
  a job is mind-bending. Their scratch is always there, always full, always
  a source of contention. This storage has zero contention — you own it
  completely for the duration of your job."

- "EFS Intelligent Tiering is the production version of this: files accessed
  in the last 30 days stay on standard EFS. Files not accessed move to
  Infrequent Access at ~92% lower cost. Automatically. No policy to write."

---

## Cost Notes

- EFS Standard: $0.30/GB-month
- EFS Intelligent Tiering (IA): $0.025/GB-month (after 30-day idle)
- A 10 GB demo workload running for 10 minutes costs < $0.01

---

## Teardown

```bash
cd terraform/workloads/scenario3-ephemeral-efs/
terraform destroy   # removes IAM policies from burst + head roles
```

The core cluster, permanent cluster EFS, and all burst nodes are untouched.
