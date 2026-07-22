# Scenario 4: Ephemeral FSx Lustre

Demonstrates job-scoped parallel filesystem storage: a Slurm job chain where
Job 1 creates an FSx Lustre filesystem linked to S3, Job 2 runs the workload
with lazy hydration from S3, and Job 3 flushes results back to S3 before
destroying the filesystem.

This is the most "cloud native" storage pattern in BurstLab: S3 is the only
permanent store, FSx is a high-performance cache that exists only during compute.

**Best for**: Audiences from environments with parallel filesystems (Lustre, GPFS,
BeeGFS) who want to understand how cloud-native HPC storage works.

---

## What It Shows

- AWS FSx Lustre API called from a burst node
- Lazy hydration: files appear in Lustre namespace immediately (as stubs), 
  data streams from S3 on first read
- Three-job chain: create FSx → compute → flush to S3 → destroy FSx
- S3 as the permanent data layer ($0.023/GB-month vs $0.14/GB-month on FSx)
- Export data repository task: explicit flush of FSx → S3 before destruction

---

## Prerequisites

1. Core cluster deployed
2. Base workloads layer applied (`terraform/workloads/base/`)
3. Scenario 4 layer applied (`terraform/workloads/scenario4-ephemeral-fsx/`)

---

## Terraform Deploy

```bash
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/base" init
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/base" apply   # if not already done

cd "$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx/"
cp terraform.tfvars.example terraform.tfvars
# Edit: gen_state_path, cluster_name
# Optional: create_fsx_service_linked_role = false (if already exists in account)
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx" init
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx" apply
# Creates S3 data bucket, grants FSx + S3 permissions, creates service-linked role
```

Get the required variables for the submit script:

```bash
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx" output cloud_subnet_a_id
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx" output fsx_sg_id
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx" output s3_data_bucket
```

---

## Demo Steps

**Step 1 — On your local workstation:** capture the three Terraform outputs, write them
to a small env file, and copy it to the head node with `scp`. Terraform is not available
on the head node, so the values must originate here:

```bash
TF=terraform/workloads/scenario4-ephemeral-fsx
HEAD_IP="<head node public IP>"

cat > /tmp/scenario4.env <<EOF
export CLOUD_SUBNET_A_ID=$(terraform -chdir="$BURSTLAB_ROOT/$TF" output -raw cloud_subnet_a_id)
export FSX_SG_ID=$(terraform -chdir="$BURSTLAB_ROOT/$TF" output -raw fsx_sg_id)
export S3_DATA_BUCKET=$(terraform -chdir="$BURSTLAB_ROOT/$TF" output -raw s3_data_bucket)
export AWS_REGION=us-west-2
EOF

scp -i "$SSH_KEY" /tmp/scenario4.env alice@"$HEAD_IP":~/scenario4.env
ssh -i "$SSH_KEY" alice@"$HEAD_IP"
```

**Step 2 — On the BurstLab head node (as alice):** source the env file (it holds the
values copied from your workstation), then submit:

```bash
source ~/scenario4.env

bash /opt/slurm/etc/workloads/jobs/scenario4/submit-chain.sh

# Watch jobs and FSx lifecycle (FSx takes 5-10 min to provision)
watch -n 10 'squeue && echo && aws fsx describe-file-systems \
  --query "FileSystems[].[FileSystemId,Lifecycle,StorageCapacity]" \
  --output table'
```

The FSx filesystem appears in the AWS console, becomes AVAILABLE, serves the
workload, flushes to S3, and disappears.

---

## Granularity Modes

Same three modes as Scenario 3 (per-job, per-array, per-campaign):

```bash
# per-job (default)
bash submit-chain.sh ...

# per-array
bash submit-chain.sh --granularity per-array --array-tasks 0-3

# per-campaign
bash submit-chain.sh --granularity per-campaign --campaign-name sweep-001
```

State files live at `/home/alice/.fsx-state/{key}.env` on permanent cluster EFS.

---

## Timing

| Phase | Duration |
|-------|----------|
| S3 input data upload | ~1 min |
| FSx create to `AVAILABLE` | **5-10 minutes** |
| Job 1 total | ~10-15 minutes |
| Job 2 (workload + lazy hydration) | ~5-15 minutes |
| S3 export task (flush results) | ~2-5 minutes |
| Job 3 total | ~5-10 minutes |
| **Total chain** | **~20-40 minutes** |

> **Note**: The long Job 1 time (FSx provisioning) is intentional — use it to
> explain the FSx architecture and lazy hydration concept while the audience
> watches `squeue`.

---

## Lazy Hydration Explained

When FSx Lustre is linked to an S3 data repository with `AutoImportPolicy=NEW_CHANGED`:

1. S3 objects appear immediately in the FSx namespace as file metadata stubs
2. The file shows its correct size, name, and timestamps
3. When an application first reads the file, FSx fetches it from S3 on demand
4. Subsequent reads come from the Lustre filesystem (full bandwidth)

```bash
# During Job 2, check hydration state on the burst node
lfs hsm_state /mnt/scratch/fsx-*/input/*
# (0x0000000d) released exists archived   <- stub, not yet on Lustre
# (0x00000009) exists archived            <- hydrated, data is local
```

This is the key mental model shift: the filesystem is a cache, not the source of truth.

---

## FSx Specification

| Parameter | Value |
|-----------|-------|
| Deployment type | SCRATCH_2 |
| Storage | 1,200 GB minimum (required by SCRATCH_2) |
| Throughput | ~240 MB/s baseline (scales with storage) |
| Cost | $0.14/GB-month (~$0.23/hr at minimum size) |
| S3 AutoImport | `NEW_CHANGED` (picks up new/modified objects automatically) |
| Mount | Lustre client with `noatime,flock` |

SCRATCH_2 is the right choice for ephemeral scratch: no replication, no maintenance
window, highest throughput per dollar.

---

## Data Flow

```
S3 (input/)              FSx (AVAILABLE)
    │                        │
    │ AutoImportPolicy        │ lazy hydration on read
    ▼                        ▼
 FSx namespace          application reads
 (stubs visible)        (data streams from S3)
                             │
                             ▼
                        FSx (output/)
                             │
                             │ Job 3: fsx_flush_to_s3()
                             ▼
                        S3 (output/)           ← permanent
                             │
                             ▼
                        FSx deleted
```

---

## SA Talking Points

- "The minimum FSx Lustre filesystem is 1,200 GB — that's about $0.23/hr.
  For a workload that runs for 2 hours, you pay $0.46 for high-performance
  parallel storage. On-prem, that same Lustre capacity exists regardless of
  whether any jobs are running."

- "Lazy hydration is the key concept. The files appear immediately in the
  namespace — the application can `ls` them, see their size, everything.
  But the bytes aren't there until the application reads them. This is how
  you run on petabytes of S3 data without pre-copying."

- "Job 3 calls `CreateDataRepositoryTask` with type `EXPORT_TO_REPOSITORY`.
  This tells FSx to flush any modified files back to S3. We wait for the task
  to complete before destroying. If we skipped this, any data written only to
  FSx would be lost."

- "S3 is $0.023/GB-month. FSx is $0.14/GB-month. Results that aren't being
  actively computed should live on S3. FSx is the cache you pay for only
  while it's needed."

- "This is what 'cloud native' actually means for HPC storage: S3 is always
  the ground truth. EFS and FSx are ephemeral high-performance layers.
  You pay only for compute + the time the scratch exists."

---

## FSx Lustre Namespace Path Behavior

FSx SCRATCH_2 with legacy data repository associations (ImportPath/ExportPath in
`LustreConfiguration`) does **not** strip the ImportPath prefix from Lustre namespace
paths. This is critical to understand for the restore workflow.

**What actually happens:**
- `ImportPath = s3://bucket/jobs/wrap-123` acts as a **filter** — it controls which
  S3 objects are imported, but does NOT define a Lustre root mapping
- S3 object `jobs/wrap-123/output/0/file.txt` appears in Lustre at the **full S3 key
  path**: `<mount_point>/jobs/wrap-123/output/0/file.txt`
- Writing to Lustre path `jobs/wrap-123/output/0/file.txt` exports to S3 at the same
  full key path via ExportPath

**Practical impact:**
- The `$SCRATCH` variable in job scripts points to the mount point, not to any prefix
  subdirectory. Your job should write to `$SCRATCH` directly and the full path hierarchy
  is preserved in S3.
- On restore, `job4-verify-restore.sh` looks for output at
  `<mount_point>/${S3_PREFIX}/output/`, not `<mount_point>/output/`, because the full
  S3 key hierarchy is mirrored into the Lustre namespace.

---

## Troubleshooting

**Job 1 fails: `FSx service-linked role`**

If you see `Unable to assume role AWSServiceRoleForAmazonFSx`:

```bash
# The role may already exist from a prior run; edit terraform.tfvars and set:
# create_fsx_service_linked_role = false
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx" apply
```

This is a **common blocker on the second run** of Terraform in a fresh AWS account.
The service-linked role is account-scoped; Terraform tries to create it on the first
apply, and the creation fails on subsequent applies if `create_fsx_service_linked_role`
is still `true`. Set it to `false` after the first successful apply.

**Job 1 fails: `Timeout waiting for FSx`**

FSx sometimes takes longer than 15 minutes to provision. Increase `--time` in
`job1-create-fsx.sh` and the `MAX_WAIT` default in `fsx-lifecycle.sh`.

**Job 2 fails: `device is busy`**

Another process may have mounted the same path. Check:
```bash
lsof /mnt/scratch/fsx-*
```

**Hydration is slow**

Lustre client tuning in `job2-run-workload.sh` sets `max_rpcs_in_flight=16`.
For large files, increase `max_pages_per_rpc` to 512.

---

## Restore Test: S3 as Permanent Store

The strongest proof that "S3 is the ground truth" is recreating an FSx filesystem
from previously-flushed S3 data and verifying the content is intact.

**Using the wrapper commands (recommended after deploying `scenario4-wrapper`):**

```bash
# Phase 1 — Submit with fsx-sbatch (creates FSx, runs workload, flushes to S3, destroys FSx)
fsx-sbatch /opt/slurm/etc/workloads/jobs/scenario4/wrapper/example-job.sh

# After the chain completes, view the run record:
fsx-list                 # shows RUN_ID, label, completed date, S3 URI, results path
fsx-list --details       # shows S3 object count per run

# Phase 2 — Restore (creates new FSx from the same S3 data, verifies checksums, destroys)
fsx-restore <RUN_ID>
# Check verification output:
cat /home/alice/logs/fsx-verify-restore-*.out

# Phase 3 — Purge S3 data when no longer needed
fsx-purge <RUN_ID>       # removes S3 data; EFS results (~/results/) are preserved
```

**Using the raw chain scripts (chain approach):**

On your **local workstation**, capture the results bucket name from Terraform output.
Terraform is **not** available on the head node, so collect the value here and pass it in:

```bash
RESULTS_BUCKET=$(terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx" output -raw s3_results_bucket)

ssh -i "$SSH_KEY" alice@<head_node_ip>
```

On the **BurstLab head node (as alice)**, substitute the bucket name printed above:

```bash
RESULTS_BUCKET="<paste value from previous step>"

# Phase 1 — Write chain
RESULTS_BUCKET=$RESULTS_BUCKET \
  bash /opt/slurm/etc/workloads/jobs/scenario4/submit-chain.sh

# Phase 2 — Restore chain
bash /opt/slurm/etc/workloads/jobs/scenario4/submit-chain-restore.sh \
  --s3-data-bucket <BUCKET> --s3-prefix <PREFIX>
cat /home/alice/logs/fsx-verify-restore-*.out
```

The restore chain creates a brand new FSx filesystem linked to the same S3 prefix.
Files appear as stubs immediately (full S3 key hierarchy mirrored into Lustre namespace
— see [FSx Lustre Namespace Path Behavior](#fsx-lustre-namespace-path-behavior) above),
hydrate from S3 on first read, and SHA256 checksums are verified against the manifest
written during the original chain.

**Two S3 buckets:**
- **Data bucket** (ephemeral, `force_destroy=true`): Input staging + FSx scratch. Cleaned
  up by `terraform destroy`.
- **Results bucket** (durable, `force_destroy=false`): Permanent results copied by job3
  after S3 flush. Persists across `terraform destroy`. Cleaned up explicitly with
  `fsx-purge <RUN_ID>`.

In a multi-account burst setup, the results bucket lives in the burst account alongside
the FSx filesystems. This separation makes the ownership model explicit: the data bucket
is ephemeral infrastructure, the results bucket is the customer's permanent store.

---

## Cost Notes

- FSx SCRATCH_2: $0.14/GB-month (1,200 GB = ~$5.40/day = $0.23/hr)
- S3 Standard: $0.023/GB-month  
- Demo chain total: ~$0.50-1.00 end to end

---

## Transparent Lifecycle Approaches

The three-job chain is the most explicit way to run this scenario. Three additional
approaches hide the create/destroy complexity so users interact with standard `sbatch`
or a drop-in wrapper.

### Approach A — Wrapper (`fsx-sbatch`)

Deploy with `terraform/workloads/scenario4-wrapper/`. Installs `fsx-sbatch` to
`/opt/slurm/bin/` on the head node.

```bash
# Job script needs only one line change:
#SBATCH --comment=fsx:1200

# Submit identically to sbatch:
fsx-sbatch /opt/slurm/etc/workloads/jobs/scenario4/wrapper/example-job.sh
# Or override storage size:
fsx-sbatch --fsx-storage=2400 myjob.sh
```

The wrapper creates FSx inline (terminal shows progress, ~5-10 min), submits the
workload with `FSX_STATE_FILE` injected, and queues the destroy job with
`--dependency=afterok`. The user sees one job ID.

**SA talking point:** "One command, one job ID. The FSx lifecycle is completely hidden.
The FSx filesystem appears in the AWS console during the workload and disappears after."

### Approach B — Prolog/Epilog

Deploy with `terraform/workloads/scenario4-prolog-epilog/`. Patches `slurm.conf` with
`PrologSlurmctld` and `EpilogSlurmctld`.

```bash
# Standard sbatch — no wrapper needed:
sbatch --comment=fsx:1200 --partition=aws \
  /opt/slurm/etc/workloads/jobs/scenario4/prolog-epilog/example-job.sh
```

The job sits in `CF` (configuring) state while the prolog provisions FSx (~5-10 min).
The epilog flushes output to S3 and destroys FSx after the job ends.

**SA talking point:** "The job stays in `CF` state while the prolog runs — that's the
FSx filesystem being provisioned. The SA narrates: 'that's creating a 1.2 TB Lustre
filesystem in AWS right now.' After the job completes, the epilog flushes to S3 and
destroys FSx automatically."

### Approach C — Burst Buffer Lua

Deploy with `terraform/workloads/scenario4-burst-buffer/`. Requires `burst_buffer/lua`
compiled into the Slurm build (Gen 1 AMI does not include it by default — the Terraform
module checks and fails fast with rebuild instructions).

```bash
# Job script uses #BB directive — industry standard from DataWarp/Cray:
#BB create_persistent name=myfsx capacity=1200GB access=striped type=scratch

sbatch /opt/slurm/etc/workloads/jobs/scenario4/burst-buffer/example-job.sh
```

Job states during lifecycle:

```
BF (stage-in)   ← FSx provisioning (~5-10 min)
R               ← workload running
CG (stage-out)  ← S3 flush + FSx destroy
```

**SA talking point:** "This is the burst buffer abstraction — the same mechanism
DataWarp uses on Cray XC systems. We're implementing the lifecycle hooks against FSx
instead of on-prem hardware. Any job script from another HPC center that uses burst
buffers can run here with minimal changes."

---

## Teardown

```bash
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx" destroy
# Removes: IAM policies, S3 data bucket (force_destroy=true), FSx service-linked role
# Does NOT destroy: the FSx filesystem (job3 handles that)
```

If wrapper, prolog/epilog, or burst-buffer modules were also applied, destroy them first:

```bash
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-burst-buffer" destroy
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-prolog-epilog" destroy
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-wrapper" destroy
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx" destroy
```

If the FSx filesystem is still running (job3 didn't complete), destroy it manually:

```bash
aws fsx delete-file-system --file-system-id fs-XXXXXXXXXXXXXXXXX --region us-west-2
```
