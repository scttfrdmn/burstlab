# Using Scratch Storage on This Cluster

You have access to on-demand scratch storage that is created when your job starts
and destroyed when it finishes. No tickets, no waiting for the storage team. You
submit a job, storage appears, your job runs, results are saved, storage disappears.

There are two types. Pick the one that fits your workload:

- **Lustre scratch** (`fsx-sbatch`) — High-bandwidth parallel filesystem backed by S3.
  Takes 5-10 minutes to provision. Use this for large datasets, many files, or
  anything that benefits from parallel I/O. Your results persist in S3 after the
  filesystem is gone, and you can re-access them later.

- **NFS scratch** (`efs-sbatch`) — Standard NFS. Ready in about 60 seconds. Use this
  when you need simple shared storage and your workload isn't I/O-bound. Results
  are copied to your home directory before the filesystem is deleted.

---

## Lustre Scratch: A Walkthrough

### 1. Write your job script

The only thing different from a normal job script is one line: `--comment=fsx:1200`.
That tells the system you want 1200 GB of Lustre scratch (the minimum size).

```bash
#!/bin/bash
#SBATCH --job-name=my-analysis
#SBATCH --partition=aws
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --time=02:00:00
#SBATCH --comment=fsx:1200

echo "Scratch filesystem is at: $SCRATCH"

# Input data is already here — it came from S3
ls $SCRATCH/input/

# Do your work
for f in $SCRATCH/input/*.dat; do
  process_data "$f" > $SCRATCH/output/$(basename "$f" .dat).result
done

echo "Done. Output files are in $SCRATCH/output/"
```

Save this as `my-analysis.sh`.

### 2. Submit your job

```bash
$ fsx-sbatch my-analysis.sh
fsx-sbatch: creating FSx SCRATCH_2 (1200 GB) — this takes 5-10 minutes...
  Creating FSx Lustre SCRATCH_2: 1200 GB @ $0.23/hr
  S3 data repository: s3://burstlab-gen1-fsx-data-abc123/jobs/wrap-1712345678/
  Waiting for FSx fs-0abc123def456 to become AVAILABLE (typically 5-10 min)...
  ...
fsx-sbatch: job 57 submitted
fsx-sbatch: results will be at ~/results/fsx-job-57-task-0/
fsx-sbatch: S3 data persists after FSx is destroyed — use 'fsx-list' to manage
57
```

You get one job ID back (57). That's your workload. Behind the scenes there's a
second job that cleans up the Lustre filesystem after yours finishes — you can
ignore it.

### 3. Watch your job

```bash
$ squeue
  JOBID PARTITION     NAME     USER ST  TIME NODES NODELIST
     57       aws my-analy    alice  R  3:21     1 aws-burst-0
     58     local fsx-dest    alice PD  0:00     1 (Dependency)
```

Job 57 is your workload running on a burst node. Job 58 is the cleanup job — it
will run automatically after 57 finishes.

### 4. Check your results

After job 57 completes:

```bash
$ ls ~/results/fsx-job-57-task-0/
checksums.txt  job-metadata.txt  file1.result  file2.result
```

These results are on permanent storage (your home directory on cluster EFS). They
won't disappear.

### 5. What if you need that data on Lustre again?

Say you realized you need to rerun the analysis with different parameters but on
the same input data. The Lustre filesystem is gone, but the data is still in S3.

```bash
$ fsx-list

COMPLETED (data in S3):
  RUN          LABEL                COMPLETED    SIZE     RESULTS
  57           default              2026-04-06   1200 GB  ~/results/fsx-job-57-task-0/

$ fsx-restore 57
=== Submitting FSx restore chain ===
  Run ID:         57
  S3 data:        s3://burstlab-gen1-fsx-data-abc123/jobs/wrap-1712345678/
  ...
```

This creates a brand new Lustre filesystem pointing at the same S3 data. Your
files appear immediately — Lustre hydrates them from S3 the first time you read
each one.

### 6. Clean up when you're done

Your results are safe on EFS (`~/results/`). The S3 copy is costing a small
amount. When you're sure you don't need it:

```bash
$ fsx-purge 57
Purge run 57

  S3 data:   s3://burstlab-gen1-fsx-data-abc123/jobs/wrap-1712345678/
  EFS results (~/results/) will NOT be deleted.

Delete S3 data for this run? [y/N] y
Deleting s3://burstlab-gen1-fsx-data-abc123/jobs/wrap-1712345678/...

Run 57 purged.
```

---

## NFS Scratch: A Walkthrough

NFS scratch works the same way, just simpler. No S3 backing, no lazy hydration.

### 1. Write your job script

```bash
#!/bin/bash
#SBATCH --job-name=quick-job
#SBATCH --partition=aws
#SBATCH --nodes=1
#SBATCH --time=00:30:00
#SBATCH --comment=efs

echo "NFS scratch is mounted"
# Your job script receives EFS_STATE_FILE in the environment
# The workload framework mounts the filesystem for you
```

### 2. Submit

```bash
$ efs-sbatch quick-job.sh
efs-sbatch: creating ephemeral EFS filesystem...
efs-sbatch: EFS fs-0abc123 is available — waiting 90s for DNS propagation...
efs-sbatch: workload job submitted: 63
63
```

Ready in about 2-3 minutes (EFS available in ~60s, plus a 90-second DNS
propagation wait before submitting). The filesystem is destroyed after your
job finishes.

> **Why the 90-second wait?** EFS DNS is AZ-specific. The burst node may land
> in either of two availability zones, and DNS for a new mount target can take
> up to 90 seconds to resolve after the target enters `available` state. The
> wrapper waits before submitting to prevent mount failures on nodes in the
> second AZ.

### 3. If something goes wrong

If your job fails and the EFS filesystem doesn't get cleaned up:

```bash
$ efs-cleanup
Scanning for orphaned BurstLab EFS filesystems...

  EFS ID                   STATE        SIZE       NAME
  fs-0abc123def456         available    1.2 GB     burstlab-ephemeral-63

  Found 1 ephemeral EFS filesystem(s).

To delete these filesystems:
  efs-cleanup --delete
```

---

## Which One Should I Use?

**Use Lustre scratch (`fsx-sbatch`) when:**
- You're processing large files or many files in parallel
- You need high bandwidth (Lustre gives you hundreds of MB/s)
- You want results backed up to S3 automatically
- You might need to re-access the data later on fresh Lustre storage
- You can wait 5-10 minutes for the filesystem to provision

**Use NFS scratch (`efs-sbatch`) when:**
- You need simple shared storage that's ready fast (~60 seconds)
- Your workload is compute-bound, not I/O-bound
- You need POSIX semantics like file locking or atomic renames
- The data is small enough that NFS throughput doesn't matter

---

## Quick Reference

```
fsx-sbatch myjob.sh         Submit with Lustre scratch
fsx-list                     Show your scratch runs (active + completed)
fsx-restore 42               Bring back old data on fresh Lustre
fsx-purge 42                 Delete S3 data for a completed run

efs-sbatch myjob.sh         Submit with NFS scratch
efs-cleanup                  Find and delete orphaned EFS
```

---

## Common Questions

**How much does scratch storage cost?**

Lustre: $0.14/GB-month. At the minimum size (1200 GB), that's about $0.23/hour.
A two-hour job costs about $0.46 for scratch storage. NFS (EFS): $0.30/GB-month,
but you only pay for data actually stored, not reserved capacity.

**Where do my results go?**

Two places: permanent EFS (`~/results/fsx-job-<ID>-task-0/`) and S3 (for Lustre
jobs). The EFS copy is immediate. The S3 copy enables `fsx-restore` later.

**Can I use a bigger filesystem?**

Yes. `fsx-sbatch --fsx-storage=2400 myjob.sh` creates a 2400 GB filesystem.
Lustre sizes must be multiples of 1200 GB.

**What happens if my job fails?**

The cleanup job runs after your workload (success or failure). If both fail,
the filesystem stays running until the cluster admin cleans up. Check `fsx-list`
or `efs-cleanup` to see if anything is orphaned.

**The `fsx-list`, `fsx-restore`, `fsx-purge`, and `efs-cleanup` commands aren't in my PATH.**

These are installed to `/opt/slurm/bin/` when the wrapper module is deployed.
That directory is added to PATH via `/etc/profile.d/slurm.sh` at login. If the
commands are missing, your cluster admin needs to deploy the wrapper Terraform
module (`scenario4-wrapper` or `scenario3-wrapper`). Log out and back in after
they do.

**Can I submit with regular `sbatch` instead of `fsx-sbatch`?**

If your cluster admin has set up the prolog/epilog approach, yes:
```bash
sbatch --comment=fsx:1200 --partition=aws myjob.sh
```
This works identically — the cluster handles everything via Slurm hooks. Ask
your admin which approach is configured on your cluster.
