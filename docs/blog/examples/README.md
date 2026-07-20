# Example configs — right-sizing Slurm nodes on AWS

Deployable companions to the post *One Partition, Many Machines: Right-Sizing Slurm
Nodes on AWS*. **All three approaches below were deployed and verified live** (AWS
ParallelCluster 3.15.1 and AWS PCS with Slurm 25.11, us-east-1, July 2026).

| File | What it is |
|---|---|
| `cluster-single-node.yaml` | Minimal baseline — head node + one compute shape in one queue. Start here. |
| `cluster-rightsizing.yaml` | The full ParallelCluster example: one user-facing partition backed by a c/m/r × 2-sizes catalog, plus a Spot mirror. |
| `slurm-overlay.conf` | The policy layer merged onto the generated `slurm.conf`: composes the unified `general` partition and caps it. |
| `pcs-rightsizing.sh` | The same model on **AWS PCS** (managed Slurm) via the CLI. |

## How the weight (cheapest-fit) knob is set — read this first

"Cheapest that fits" = Slurm picks, among nodes whose `CPUs` **and** `RealMemory`
satisfy the job, the one with the lowest **`Weight`**. How you set that Weight differs
by platform — and one tempting approach does **not** work:

- ❌ **Do NOT** add `NodeName=... Weight=N` lines to the `CustomSlurmSettingsIncludeFile`.
  Slurm treats a second `NodeName` line for an existing node as a *duplicate definition*
  and `slurmctld` dies with `fatal: Duplicated NodeHostName ...` — the cluster fails to
  create. (We hit this; it's why the overlay contains no weight lines.)
- ✅ **ParallelCluster:** set **`DynamicNodePriority`** on each compute resource (maps to
  Slurm `Weight`; default 1000; requires pcluster ≥ 3.7.0). See `cluster-rightsizing.yaml`.
- ✅ **PCS:** set **`Weight`** via `slurmCustomSettings` on each compute node group (it's
  on the documented allow-list). See `pcs-rightsizing.sh`.

## The two-file split (ParallelCluster) — and why

ParallelCluster generates the base `slurm.conf` (the `NodeName` / `NodeSet` /
`PartitionName` plumbing) from the YAML, and creates one partition per queue. So:

- **`cluster-rightsizing.yaml`** defines the hardware as two building-block queues,
  `cpu-od` (On-Demand) and `cpu-spot` (Spot) — separate because `CapacityType` is
  per-queue — with `DynamicNodePriority` setting each shape's weight.
- **`slurm-overlay.conf`** unions the two queues' node sets into a single `general`
  partition users submit to, hides the raw building-block partitions, and caps the
  partition with `MaxNodes`.

## Deploy (ParallelCluster)

```bash
# 0. Fill in every REPLACE_ME_* (subnet, key pair, S3 bucket) in the YAML + overlay.

# 1. The head node needs S3 read on the overlay bucket (HeadNode.Iam.S3Access in the
#    YAML). Upload the overlay there:
aws s3 cp slurm-overlay.conf s3://REPLACE_ME_BUCKET/slurm-overlay.conf

# 2. Create the cluster
pcluster create-cluster --cluster-name demo \
  --cluster-configuration cluster-rightsizing.yaml --region us-east-1

# 3. When CREATE_COMPLETE, SSH in and confirm the partition + weights
pcluster ssh --cluster-name demo
sinfo -N -o '%N %c %m %w'      # node, cpus, memory, weight
```

## See it right-size (without spending anything)

`--test-only` asks Slurm where a job *would* land without launching an instance. These
are the **actual results** from the verified cluster:

```bash
sbatch --test-only -p general -c 4  --mem=8G   --wrap true   # -> a c-2xl (cheapest, all fit)
sbatch --test-only -p general -c 4  --mem=48G  --wrap true   # -> an r-2xl (48G rules out 16/32G)
sbatch --test-only -p general -c 24 --mem=48G  --wrap true   # -> a c-8xl (24 cores forces 8xlarge)
sbatch --test-only -p general -c 8  --mem=200G --wrap true   # -> an r-8xl (only 256G clears 200G)
```

With Spot in the pool, the chosen node is the `cpu-spot` variant of each (lower weight);
if Spot capacity is unavailable, Slurm requeues onto the On-Demand twin — the fallback
is automatic (also verified).

## Notes

- **Weights are illustrative** (`≈ hourly price × 100`). Only the *relative order*
  matters to the scheduler. Real generated values on the test cluster: OD 37/46/59/148/
  184/236, Spot 11/14/18/44/55/71.
- **`RealMemory` is ~95% of nominal** — pcluster reserves headroom (e.g. a 16 GB
  c8i.2xlarge shows `RealMemory=15564`). Size `--mem` requests with that in mind.
- **`sacct` needs Slurm accounting.** A bare cluster has none (`sacct` → "accounting
  storage is disabled"); add a `Scheduling/SlurmSettings/Database` section to compare
  requested vs. used per job. Without it, use `scontrol show job <id>` (shows `ReqTRES`).
- **Instance types are July-2026 current** (`c8i`/`m8i`/`r8i`, Intel). Swap for
  `c8g`/`m8g`/`r8g` for Graviton. Update as newer generations ship.
- **Teaching examples**, trimmed for clarity — no shared storage, custom AMIs, or auth.
  Add those for a real deployment.
