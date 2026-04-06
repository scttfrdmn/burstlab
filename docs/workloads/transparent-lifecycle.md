# Transparent Storage Lifecycle: Approach Comparison

Scenarios 3 (EFS) and 4 (FSx) demonstrate ephemeral storage that is created when a job
starts and destroyed when it ends. This document compares the four approaches available,
from most explicit to most transparent.

For the cluster user's perspective, see [user-guide.md](user-guide.md).

### Testing Status

| Approach | Gen 1 | Gen 2 | Gen 3 | Notes |
|----------|-------|-------|-------|-------|
| **0 — Chain** | Tested (FSx + EFS) | Not tested | Not tested | End-to-end on live Gen 1 cluster |
| **A — Wrapper** | Not tested | Not tested | Not tested | Uses same fsx-lifecycle.sh as tested chain |
| **B — Prolog/Epilog** | Not tested | Not tested | Not tested | Requires `scontrol update ... Environment=` (Slurm 21.08+, all gens qualify) |
| **C — Burst Buffer** | Cannot run | Not tested | Not tested | Requires `burst_buffer_lua.so` — not in current AMIs; needs `--with-lua` rebuild |

The wrapper and prolog/epilog approaches share the proven `fsx-lifecycle.sh` and
`efs-lifecycle.sh` libraries. The primary risk is in the integration glue (env
injection, `scontrol update`, combined dispatcher), not in the AWS API calls.

Gen 2 and Gen 3 use different Slurm versions (23.11 and 24.05) but the lifecycle
scripts use only stable Slurm APIs. The main Gen 2/3 risk is untested cloud-init
paths for the Lustre client and mount tooling.

---

## The Four Approaches

| | **0 — Chain** | **A — Wrapper** | **B — Prolog/Epilog** | **C — Burst Buffer** |
|---|---|---|---|---|
| **How to submit** | `bash submit-chain.sh` | `fsx-sbatch myjob.sh` | `sbatch --comment=fsx:1200 myjob.sh` | `sbatch myjob.sh` (with `#BB`) |
| **Job script changes** | None | Add `#SBATCH --comment=fsx:N` | Add `#SBATCH --comment=fsx:N` | Add `#BB create_persistent` |
| **Visible to user** | 3 job IDs with dependencies | 1 job ID | 1 job ID; job in CF during provisioning | BF → R → CG states |
| **Where storage is created** | Burst node (Job 1) | Head node (wrapper) | Head node (prolog) | Head node (data_in hook) |
| **Deployment required** | None | `scenario{3,4}-wrapper/` | `scenario{3,4}-prolog-epilog/` | `scenario4-burst-buffer/` |
| **slurm.conf change** | None | None | `SlurmctldProlog/Epilog` added | `BurstBufferType` added |
| **Slurm version req.** | Any | Any (21.08+ for env inject) | 21.08+ (`scontrol update ... Environment=`) | Requires `burst_buffer/lua.so` in build |
| **FSx support** | Yes | Yes | Yes | Yes |
| **EFS support** | Yes | Yes | Yes | No (BB is for high-perf scratch) |

---

## Approach 0 — Chain (`submit-chain.sh`)

The baseline approach. Three Slurm jobs submitted with `--dependency`:

```
Job 1 (local): create storage, write state file
Job 2 (aws):   run workload (reads state file)   ← afterok:Job1
Job 3 (local): flush to S3 (FSx only), destroy   ← afterok:Job2
```

**Deploy:** No extra Terraform needed beyond `scenario{3,4}-ephemeral-{efs,fsx}/`.

**When to use:** Teaching the mechanics. The three-job chain makes every lifecycle
step explicit — customers see exactly what is happening and when.

**SA talking point:** "Each job does one thing. You can watch the EFS/FSx console as
Job 1 runs, see the filesystem appear, watch Job 2 use it, and watch Job 3 clean it up.
Nothing is hidden. For a customer learning about ephemeral storage for the first time,
this is the right level of transparency."

---

## Approach A — Wrapper

A drop-in wrapper (`fsx-sbatch` / `efs-sbatch`) installed to `/opt/slurm/bin/` ahead
of the real `sbatch` in PATH. Real `sbatch` is at `/opt/slurm-baked/bin/sbatch`.

```bash
fsx-sbatch myjob.sh          # creates FSx inline, submits job, queues destroy
efs-sbatch myjob.sh          # same for EFS
fsx-sbatch --fsx-storage=2400 myjob.sh   # override storage size
```

The job script signals its intent:

```bash
#SBATCH --comment=fsx:1200   # FSx, 1200 GB minimum
#SBATCH --comment=efs        # EFS
```

Jobs without the comment pass through to real `sbatch` unchanged.

**What the wrapper does:**
1. Parses `--comment=fsx:N` from the job script
2. Creates FSx/EFS inline (live progress in terminal, 5-10 min for FSx, ~60s for EFS)
3. Submits the workload with `--export=ALL,FSX_STATE_FILE=<path>`
4. Submits a destroy job to `--partition=local` with `--dependency=afterok:<workload_job_id>`
5. Returns the workload job ID (destroy is invisible)

**Deploy:**
```bash
cd terraform/workloads/scenario4-wrapper/
terraform init && terraform apply
# Writes /etc/sysconfig/burstlab-workloads, installs fsx-sbatch to /opt/slurm/bin/
```

**When to use:** Customers who want zero changes to their job scheduler config. The
wrapper is the fastest path to transparent lifecycle — install one binary, submit jobs
the same way.

**SA talking point:** "The user typed one command and got one job ID back. Everything
else — the FSx create, the environment injection, the flush and destroy — is invisible.
If a customer's users already submit jobs to the cluster, the only change is the
command prefix."

---

## Approach B — Prolog/Epilog

Uses Slurm's `SlurmctldProlog` and `SlurmctldEpilog` hooks, which run on the head node
as `SlurmUser` before and after every job.

```bash
sbatch --comment=fsx:1200 --partition=aws myjob.sh
```

The prolog checks `SLURM_JOB_COMMENT`:
- `fsx:N` → creates FSx, waits for AVAILABLE, injects `FSX_STATE_FILE` via `scontrol update`
- `efs`   → creates EFS, waits for mount target, injects `EFS_STATE_FILE`
- anything else → exit 0 immediately (zero cost for all other jobs)

Jobs without the trigger comment run without any overhead.

**Deploy:**
```bash
cd terraform/workloads/scenario4-prolog-epilog/
terraform init && terraform apply
# Deploys scripts to /opt/slurm/etc/scripts/
# Idempotently patches slurm.conf with SlurmctldProlog/Epilog/PrologEpilogTimeout=1800
# Runs scontrol reconfigure (no slurmctld restart needed)
```

**Coexistence:** If both scenario3-prolog-epilog and scenario4-prolog-epilog are applied,
they share a single combined `storage-slurmctld-prolog.sh` dispatcher that handles both
`fsx:` and `efs` comment prefixes. Slurm only allows one `SlurmctldProlog` line.

**When to use:** Clusters that already use prolog/epilog for other purposes (license
checkout, CVMFS warming, container pull). The `--comment` convention integrates cleanly
with whatever existing prolog logic is already in place.

**SA talking point:** "The prolog/epilog hooks are standard Slurm — most production
clusters already have them. We're just adding storage lifecycle as one more thing the
prolog handles. The job submitter only needs to know `--comment=fsx:1200`. The cluster
admin deploys the prolog once and it applies to all partitions automatically."

---

## Approach C — Burst Buffer Lua (FSx only)

Uses Slurm's `burst_buffer/lua` plugin, which maps job lifecycle stages to a Lua script.
This is the same abstraction as DataWarp on Cray XC systems.

```bash
# Job script:
#BB create_persistent name=myfsx capacity=1200GB access=striped type=scratch
#SBATCH --partition=aws

sbatch myjob.sh
```

Job states visible in `squeue`:

```
BF   ← FSx provisioning (stage-in, ~5-10 min)
R    ← workload running
CG   ← S3 flush + FSx destroy (stage-out)
```

**Lifecycle hooks:**

| Hook | What it does |
|------|-------------|
| `slurm_bb_job_process` | Validates `#BB` directive at submit time (fails fast if syntax wrong) |
| `slurm_bb_data_in` | Creates FSx, waits for AVAILABLE, writes state file (job in BF) |
| `slurm_bb_pre_run` | Injects `FSX_STATE_FILE` env var via `slurm.job_environment_set` |
| `slurm_bb_post_run` | Flushes output to S3 (job in CG) |
| `slurm_bb_data_out` | Destroys FSx, removes state file |

**Prerequisite — Lua plugin in Slurm build:**

`burst_buffer/lua.so` must be compiled into the Slurm build. Verify:

```bash
ls /opt/slurm-baked/lib/slurm/burst_buffer_lua.so
```

The Gen 1 AMI (`rocky8-slurm2205.pkr.hcl`) does not include this by default. The
`scenario4-burst-buffer/` Terraform module checks for the plugin and fails with a
clear error message and rebuild instructions if it is absent. To enable it, rebuild
the AMI with `--with-lua` in the `./configure` step.

**Deploy:**
```bash
cd terraform/workloads/scenario4-burst-buffer/
terraform init && terraform apply
# Checks burst_buffer_lua.so is present (fails fast if not)
# Installs lua via dnf if needed
# Deploys fsx-bb.lua to /opt/slurm/etc/
# Patches slurm.conf with BurstBufferType + BBLuaScriptFile
# Runs scontrol reconfigure
```

**When to use:** Customers from Cray/HPE Slingshot environments, or any site that
already uses burst buffers for other storage (DataWarp, BeeGFS BB). The `#BB` directive
is portable across burst buffer implementations.

**SA talking point:** "This is the burst buffer abstraction — the same mechanism
DataWarp uses on Cray XC systems, GPFS Burst Buffer on IBM Spectrum LSF, and Lustre HSM
on most Tier 1 HPC centers. We're implementing the lifecycle hooks against FSx instead
of on-prem hardware. The `#BB` directive is industry standard. Any job script from
another HPC center that uses burst buffers can run here with minimal changes — the only
difference is the pool name."

**Note:** EFS is intentionally excluded from the burst buffer approach. Burst buffers
are designed for high-performance scratch tiers. Demonstrating burst buffer with
NFS-based EFS would send the wrong message about when to use each abstraction.

---

## Choosing an Approach

```
Customer question: "How do we hide the create/destroy from our users?"

Is the cluster new or are they adding bursting from scratch?
  → Burst Buffer (C) if they know DataWarp/Cray, otherwise Prolog/Epilog (B)

Does the cluster already have SlurmctldProlog configured?
  → Prolog/Epilog (B) — add storage lifecycle to the existing hook

Does the customer want zero scheduler config changes?
  → Wrapper (A) — one binary install, done

Is this a teaching/discovery conversation?
  → Chain (0) — show every step explicitly, then demo Wrapper to contrast
```

---

## Side-by-Side Demo

For an SA demo, running all three approaches back-to-back makes the contrast vivid:

```bash
# 0 — Chain: show the explicit three-job dependency
bash /opt/slurm/etc/workloads/jobs/scenario4/submit-chain.sh
# Audience sees: 3 job IDs, dependency arrows in squeue

# A — Wrapper: deploy, then run
fsx-sbatch /opt/slurm/etc/workloads/jobs/scenario4/wrapper/example-job.sh
# Audience sees: 1 job ID, FSx created inline with progress output

# B — Prolog/Epilog: just sbatch
sbatch --comment=fsx:1200 --partition=aws \
  /opt/slurm/etc/workloads/jobs/scenario4/prolog-epilog/example-job.sh
# Audience sees: 1 job ID, job in CF while FSx provisions

# (C requires AMI rebuild to enable burst_buffer/lua.so)
```

The progression — from explicit to transparent — is the demo narrative itself.
