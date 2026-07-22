# Scenario 2: RODA Datasets (S3 Access)

Demonstrates reading public cloud datasets directly from S3 using three
different tools: s5cmd (fastest), rclone (integrity-verified), and AWS
Mountpoint for S3 (zero code change POSIX access).

The Registry of Open Data on AWS (RODA) hosts petabytes of scientific datasets
that HPC applications can read without moving data into on-prem storage first.

**Best for**: Audiences with genomics, earth science, or climate data workloads.

---

## What It Shows

- Three ways to consume S3 data from a burst node
- s5cmd: parallel, high-throughput bulk transfer
- rclone: checksum-verified transfer (bit-perfect)
- Mountpoint: POSIX filesystem over S3 (zero application changes)
- Results written back to a private S3 results bucket

---

## Prerequisites

1. Core cluster deployed
2. Base workloads layer applied (`terraform/workloads/base/`)
3. Scenario 2 layer applied (`terraform/workloads/scenario2-roda/`)

---

## Terraform Deploy

Run on your **local workstation** (paths are from `$BURSTLAB_ROOT` — see the
[quickstart](../quickstart.md#before-you-start) for the setup that exports it):

```bash
# Base overlay (once per cluster, if not already applied)
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/base" init
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/base" apply

# Scenario 2
cd "$BURSTLAB_ROOT/terraform/workloads/scenario2-roda/"
cp terraform.tfvars.example terraform.tfvars
# Edit: roda_bucket = "noaa-goes16"   (or any RODA bucket)
#       results_bucket_name = "burstlab-roda-results-<suffix>"
terraform init && terraform apply
# Creates results bucket + adds S3 read policy to burst node role
```

The burst node role gains S3 read access to the RODA bucket and write access
to the results bucket. No other permissions change.

> **Region note:** `noaa-goes16` lives in `us-east-1`. Reading it from a cluster in a
> different region (e.g. the `us-west-2` default) still works, but incurs cross-region
> data-transfer cost and latency. For the free-egress, same-region story described
> below, deploy this scenario's cluster in `us-east-1`. Region is set in **three**
> places that must agree — exporting `AWS_REGION` alone is not enough, because Packer
> and Terraform read their own variables: `export AWS_REGION=us-east-1` (CLI), pass
> `-var aws_region=us-east-1` to `packer build`, and set `aws_region = "us-east-1"` in
> `terraform.tfvars`. The commands are otherwise identical.

---

## Demo Steps

**Step 1 — On your local workstation:** capture the results bucket name from Terraform
output and open an SSH session that carries the value into the remote shell. Terraform
is not available on the head node, so the value must come from here:

```bash
HEAD_IP="<head node public IP>"
RESULTS_BUCKET=$(terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario2-roda" \
  output -raw results_bucket_name)

# Open an interactive session with RESULTS_BUCKET already exported in it:
ssh -i "$SSH_KEY" alice@"$HEAD_IP" \
  "export RESULTS_BUCKET='$RESULTS_BUCKET'; exec bash -l"
```

**Step 2 — On the BurstLab head node (as alice):** `RESULTS_BUCKET` is already set in the
session opened above (confirm with `echo "$RESULTS_BUCKET"`). Submit the jobs:

```bash
# s5cmd: fastest parallel download
RESULTS_BUCKET=$RESULTS_BUCKET AWS_REGION=us-west-2 \
  sbatch /opt/slurm/etc/workloads/jobs/scenario2/roda-s5cmd.sh

# rclone: checksummed download
RESULTS_BUCKET=$RESULTS_BUCKET AWS_REGION=us-west-2 \
  sbatch /opt/slurm/etc/workloads/jobs/scenario2/roda-rclone.sh

# Mountpoint: POSIX access (no download)
RESULTS_BUCKET=$RESULTS_BUCKET AWS_REGION=us-west-2 \
  sbatch /opt/slurm/etc/workloads/jobs/scenario2/roda-mountpoint.sh

# Watch jobs
watch -n 5 squeue

# Results in S3
aws s3 ls s3://${RESULTS_BUCKET}/ --recursive
```

> If you deployed in `us-east-1` per the region note above, set `AWS_REGION=us-east-1`
> in the `sbatch` lines to match.

---

## Dataset: NOAA GOES-16

The default demo dataset is NOAA GOES-16 ABI Level 2 Cloud and Moisture Imagery
(CMIP), a 10-minute cadence satellite imagery product in NetCDF format. This is
a good demo dataset because:

- Files are 50-200 MB each (not trivially small)
- No license required (RODA public access)
- Familiar to atmospheric science and climate modeling audiences
- Available in `us-east-1` (free egress to compute in same region)

To change the dataset:
```bash
RODA_BUCKET=noaa-nexrad-level2 \
RODA_PREFIX=2023/01/01/KBMX/ \
  sbatch /opt/slurm/etc/workloads/jobs/scenario2/roda-s5cmd.sh
```

---

## Tool Comparison

| Tool | Speed | Integrity | POSIX | Code Change |
|------|-------|-----------|-------|-------------|
| s5cmd | Fastest | None | No | Yes (use s5cmd) |
| rclone | Fast | Checksum | No | Yes (use rclone) |
| Mountpoint | Streaming | None | Yes | None |

**s5cmd** is best when you need to move large amounts of data quickly and trust
the source (AWS checksum at upload means data is correct if the API says it is).

**rclone** is best for genomics, observational data, or any case where a corrupt
transfer would invalidate the analysis. `--checksum` verifies end-to-end.

**Mountpoint** is best when the application already reads from a POSIX path
and you want zero code changes. Files stream from S3 on first read.

---

## SA Talking Points

- "RODA means the data is already in AWS. There's no egress cost to read it —
  data that lives in `us-east-1` is free to read from an EC2 instance in the
  same region. Your on-prem cluster would have to download petabytes; your
  burst nodes just read it directly."

- "rclone's `--checksum` flag verifies every byte against the S3 ETag. For
  genomics or observational data where a single corrupt read invalidates the
  analysis, this is the right choice."

- "Mountpoint presents S3 as a POSIX filesystem. The application doesn't know
  it's reading from S3. It just opens a file. Files are streamed as they're
  read — no pre-copy, no code changes."

- "s5cmd is 3-5x faster than the AWS CLI for bulk transfers. It handles
  multipart automatically. If your workflow is 'copy 10 TB from S3 before
  compute', s5cmd is what you want."

---

## Teardown

Run on your **local workstation**:

```bash
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario2-roda" destroy
# removes results bucket (force_destroy=true), IAM policy
```

The RODA bucket is not affected — it's a public AWS-managed dataset.
