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
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/base" init
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/base" apply   # if not already done

cd "$BURSTLAB_ROOT/terraform/workloads/scenario3-ephemeral-efs/"
cp terraform.tfvars.example terraform.tfvars
# Edit — deployment-coupled: gen_state_path (always) + aws_profile, aws_region,
#        cluster_name if you left the Gen 1 / aws / us-west-2 defaults behind.
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario3-ephemeral-efs" init
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario3-ephemeral-efs" apply
# Grants EFS lifecycle permissions to burst + head node IAM roles
```

After apply, get the subnet and security group IDs needed by the submit script:

```bash
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario3-ephemeral-efs" output cloud_subnet_a_id
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario3-ephemeral-efs" output efs_sg_id
```

---

## Demo Steps

**Step 1 — On your local workstation:** capture the two Terraform outputs, write them to
a small env file, and copy it to the head node with `scp`. Terraform is not available on
the head node, so the values must originate here:

```bash
TF=terraform/workloads/scenario3-ephemeral-efs
HEAD_IP="<head node public IP>"

cat > /tmp/scenario3.env <<EOF
export CLOUD_SUBNET_A_ID=$(terraform -chdir="$BURSTLAB_ROOT/$TF" output -raw cloud_subnet_a_id)
export EFS_SG_ID=$(terraform -chdir="$BURSTLAB_ROOT/$TF" output -raw efs_sg_id)
export AWS_REGION=$AWS_REGION
EOF

scp -i "$SSH_KEY" /tmp/scenario3.env alice@"$HEAD_IP":~/scenario3.env
ssh -i "$SSH_KEY" alice@"$HEAD_IP"
```

**Step 2 — On the BurstLab head node (as alice):** source the env file (it holds the
values copied from your workstation), then submit the three-job chain:

```bash
source ~/scenario3.env

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

# End campaign (submit destroy manually). AWS_REGION/EFS_SG_ID come from the sourced
# ~/scenario3.env, so they already match your deployment — no need to hardcode them.
CAMPAIGN_NAME=protein-sweep \
  sbatch jobs/scenario3/job3-destroy-efs.sh
```

---

## Timing

| Phase | Duration |
|-------|----------|
| EFS create to `available` | ~30-60 seconds |
| Mount target creation (per AZ) | ~30 seconds |
| DNS propagation wait | **~90 seconds** |
| Job 1 total (with polling) | ~2-3 minutes |
| Job 2 (demo workload) | ~1-2 minutes |
| Job 3 (destroy) | ~1-2 minutes |
| Total chain | ~5-7 minutes |

> **Why two mount targets?** EFS DNS resolves to an AZ-local endpoint. Burst
> nodes can land in either of two availability zones (cloud subnets a and b).
> Both mount targets must exist and be `available` before jobs are submitted,
> otherwise nodes in the second AZ cannot resolve the EFS hostname.
>
> **Why the DNS wait?** EFS DNS for a newly-created mount target can take up to
> 90 seconds to propagate after the mount target enters `available` state. The
> wrapper (`efs-sbatch`) waits 90 seconds before submitting the workload job to
> prevent intermittent mount failures.

---

## State File

Job 1 writes a state file to `/home/alice/.efs-state/{key}.env` on permanent
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

## Transparent Lifecycle Approaches

The three-job chain is the most explicit way to run this scenario. Two additional
approaches hide the create/destroy complexity so users interact with standard `sbatch`.

### Approach A — Wrapper (`efs-sbatch`)

Deploy with `terraform/workloads/scenario3-wrapper/`. Installs `efs-sbatch` to
`/opt/slurm/bin/` on the head node.

```bash
# Job script needs only one line change:
#SBATCH --comment=efs

# Submit identically to sbatch:
efs-sbatch /opt/slurm/etc/workloads/jobs/scenario3/wrapper/example-job.sh
```

The wrapper creates EFS inline (terminal shows progress, ~60s), creates mount targets
in **both** cloud subnets (a and b), waits 90 seconds for DNS propagation, submits the
workload with `EFS_STATE_FILE` injected into the environment, and queues the destroy job
with `--dependency=afterok`. The user sees one job ID. The destroy job appears in `squeue`
as `(Dependency)` but can be ignored.

> **IAM (handled automatically):** the destroy job needs `elasticfilesystem:*`. The
> Scenario 3 overlay attaches the `burstlab-workloads-efs-lifecycle` policy to **both**
> the head node and burst node roles for you (see `aws_iam_role_policy` in
> `terraform/workloads/scenario3-ephemeral-efs/main.tf`) — no manual IAM console step is
> required. (Compute nodes run destroy jobs under the head node instance profile; there
> is no separate compute-node role to attach to.)

**SA talking point:** "One command, one job ID. The EFS lifecycle — create, inject,
destroy — is completely hidden. If the cluster already has a similar wrapper for other
purposes, migration cost is zero."

### Approach B — Prolog/Epilog

Deploy with `terraform/workloads/scenario3-prolog-epilog/`. Patches `slurm.conf` with
`PrologSlurmctld` and `EpilogSlurmctld` pointing to a combined storage dispatcher.

```bash
# Standard sbatch — no wrapper needed:
sbatch --comment=efs --partition=aws \
  /opt/slurm/etc/workloads/jobs/scenario3/prolog-epilog/example-job.sh
```

The prolog detects `--comment=efs`, creates EFS, injects `EFS_STATE_FILE` via
`scontrol update JobId=N Environment=...`. The epilog destroys EFS after the job ends.
Jobs without `--comment=efs` pass through with no overhead.

**SA talking point:** "The `--comment` field is the only job script change. Everything
else is standard `sbatch`. The prolog and epilog run on the head node as `SlurmUser`,
so no EC2 instances are needed for create/destroy."

---

## Teardown

```bash
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario3-ephemeral-efs" destroy   # removes IAM policies from burst + head roles
```

If wrapper or prolog/epilog modules were also applied, destroy them first:

```bash
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario3-prolog-epilog" destroy
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario3-wrapper" destroy
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario3-ephemeral-efs" destroy
```

The core cluster, permanent cluster EFS, and all burst nodes are untouched.
