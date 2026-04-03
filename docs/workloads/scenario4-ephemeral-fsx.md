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
cd terraform/workloads/base/
terraform init && terraform apply   # if not already done

cd terraform/workloads/scenario4-ephemeral-fsx/
cp terraform.tfvars.example terraform.tfvars
# Edit: gen_state_path, cluster_name
# Optional: create_fsx_service_linked_role = false (if already exists in account)
terraform init && terraform apply
# Creates S3 data bucket, grants FSx + S3 permissions, creates service-linked role
```

Get the required variables for the submit script:

```bash
terraform output cloud_subnet_a_id
terraform output fsx_sg_id
terraform output s3_data_bucket
```

---

## Demo Steps

```bash
ssh alice@<head_node_ip>

CLOUD_SUBNET_A_ID=$(cd terraform/workloads/scenario4-ephemeral-fsx/ && terraform output -raw cloud_subnet_a_id)
FSX_SG_ID=$(cd terraform/workloads/scenario4-ephemeral-fsx/ && terraform output -raw fsx_sg_id)
S3_DATA_BUCKET=$(cd terraform/workloads/scenario4-ephemeral-fsx/ && terraform output -raw s3_data_bucket)

CLOUD_SUBNET_A_ID=$CLOUD_SUBNET_A_ID \
FSX_SG_ID=$FSX_SG_ID \
S3_DATA_BUCKET=$S3_DATA_BUCKET \
AWS_REGION=us-west-2 \
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

State files live at `/u/home/alice/.fsx-state/{key}.env` on permanent cluster EFS.

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

## Troubleshooting

**Job 1 fails: `FSx service-linked role`**

If you see `Unable to assume role AWSServiceRoleForAmazonFSx`:

```bash
cd terraform/workloads/scenario4-ephemeral-fsx/
# The role may already exist from a prior run; set:
# create_fsx_service_linked_role = false
terraform apply
```

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

## Cost Notes

- FSx SCRATCH_2: $0.14/GB-month (1,200 GB = ~$5.40/day = $0.23/hr)
- S3 Standard: $0.023/GB-month  
- Demo chain total: ~$0.50-1.00 end to end

---

## Teardown

```bash
cd terraform/workloads/scenario4-ephemeral-fsx/
terraform destroy
# Removes: IAM policies, S3 data bucket (force_destroy=true), FSx service-linked role
# Does NOT destroy: the FSx filesystem (job3 handles that)
```

If the FSx filesystem is still running (job3 didn't complete), destroy it manually:

```bash
aws fsx delete-file-system --file-system-id fs-XXXXXXXXXXXXXXXXX --region us-west-2
```
