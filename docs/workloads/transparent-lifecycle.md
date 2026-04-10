# Transparent Storage Lifecycle: Approach Comparison

Scenarios 3 (EFS) and 4 (FSx) demonstrate ephemeral storage that is created when a job
starts and destroyed when it ends. This document compares the four approaches available,
from most explicit to most transparent.

For the cluster user's perspective, see [user-guide.md](user-guide.md).

### Testing Status

| Approach | Gen 1 | Gen 2 | Gen 3 | Notes |
|----------|-------|-------|-------|-------|
| **0 — Chain** | Tested (FSx + EFS) | Not tested | Not tested | End-to-end on live Gen 1 cluster |
| **A — Wrapper** | Tested (FSx + EFS) | Not tested | Not tested | fsx-sbatch + efs-sbatch end-to-end on Gen 1; fsx-restore + fsx-purge verified |
| **B — Prolog/Epilog** | Tested (FSx + EFS) | Tested (FSx + EFS) | Tested (EFS only) | FSx blocked: no EL10 Lustre client in AWS repo. EFS works. `scontrol update Environment=` NOT supported in 22.05 or 23.11; state file path instead |
| **C — Burst Buffer** | Cannot run | Not tested | Not tested | Requires `burst_buffer_lua.so` — not in current AMIs; needs `--with-lua` rebuild |

The wrapper and prolog/epilog approaches share the proven `fsx-lifecycle.sh` and
`efs-lifecycle.sh` libraries. The primary risk is in the integration glue (env
injection, `scontrol update`, combined dispatcher), not in the AWS API calls.

Gen 2 (Slurm 23.11, Rocky 9) is fully validated for Approach B. Gen 3 (Slurm 24.05,
Rocky 10) is validated for EFS only — FSx Lustre is blocked (see Gen 3 notes below).

**Gen 2 operational notes (Slurm 23.11.10, Rocky 9, AMI `ami-069e41e072fedcf8e`):**
- `scontrol update Environment=` is NOT supported in 23.11.10 (returns "Update of
  this parameter is not supported") — deterministic state file path workaround required
- **FSx Lustre version:** The Lustre client version varies by OS: EL8 has 2.12.x, EL9 has
  2.15.x. FSx SCRATCH_2 must be created with a matching `--file-system-type-version`.
  `fsx-lifecycle.sh` auto-detects the OS major version and sets `FSX_LUSTRE_VERSION`
  accordingly (override via env var if needed).
- **EFS DNS propagation:** Route 53 private hosted zone records for new EFS mount targets
  take >5 minutes to propagate after the mount target reaches `available` state — even
  head node `nslookup` fails during this window. Mount using the IP address directly
  (returned by `efs_get_mount_target_ip()` in `efs-lifecycle.sh`). The prolog writes
  `EFS_MOUNT_IP` to the state file; the job script uses `${EFS_MOUNT_IP:-${EFS_DNS}}`.

**Gen 3 operational notes (Slurm 24.05.5, Rocky 10, AMI `ami-0e6d8478ca888e22d`):**
- **FSx Lustre: blocked.** The AWS FSx Lustre client repo (`fsx-lustre-client-repo.s3.amazonaws.com`)
  does not publish packages for `el/10`. `burst-node-init.sh.tpl` installs with
  `skip_if_unavailable=1`, so the node boots cleanly but has no Lustre kernel module.
  FSx workloads fail at `modprobe lustre`. EFS workloads are unaffected.
- **EFS:** Fully functional. IP-based mount workaround applies here too.
- **Crypto policy:** DEFAULT (no LEGACY). `burstlab-key` is Ed25519 across all
  generations, which is not affected by RHEL 10's RSA-3072 minimum.
- **PrologSlurmctld syntax:** Slurm 24.05 shows `PrologSlurmctld[0]` (array syntax)
  in `scontrol show config`, but behavior is identical.

---

## The Four Approaches

| | **0 — Chain** | **A — Wrapper** | **B — Prolog/Epilog** | **C — Burst Buffer** |
|---|---|---|---|---|
| **How to submit** | `bash submit-chain.sh` | `fsx-sbatch myjob.sh` | `sbatch --comment=fsx:1200 myjob.sh` | `sbatch myjob.sh` (with `#BB`) |
| **Job script changes** | None | Add `#SBATCH --comment=fsx:N` | Add `#SBATCH --comment=fsx:N` | Add `#BB create_persistent` |
| **Visible to user** | 3 job IDs with dependencies | 1 job ID | 1 job ID; job in CF during provisioning | BF → R → CG states |
| **Where storage is created** | Burst node (Job 1) | Head node (wrapper) | Head node (prolog) | Head node (data_in hook) |
| **Deployment required** | None | `scenario{3,4}-wrapper/` | `scenario{3,4}-prolog-epilog/` | `scenario4-burst-buffer/` |
| **slurm.conf change** | None | None | `PrologSlurmctld/Epilog` added | `BurstBufferType` added |
| **Slurm version req.** | Any | Any | Any (PREP plugin `prep/script` required; env inject via `scontrol update Environment=` works on 23.02+, not 22.05) | Requires `burst_buffer/lua.so` in build |
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

**Live testing notes (Gen 1):**
- FSx Lustre legacy DRA mirrors the **full S3 key path** from the bucket root into the
  Lustre namespace. `ImportPath` is a filter, not a root mapping. Data written to Lustre
  path `output/` is exported to S3 at `${S3_PREFIX}/output/` (via ExportPath). On restore,
  the same S3 data appears in Lustre at `${MOUNT_POINT}/${S3_PREFIX}/output/`.
- EFS mount targets must exist in **both** cloud subnets (a and b). EFS DNS is AZ-specific;
  burst nodes can land in either AZ. Without the second mount target, the DNS fails to
  resolve on nodes in the wrong AZ.
- EFS DNS propagation takes up to 90s after a mount target enters `available` state. The
  wrapper waits 90s before submitting the workload job.
- Compute nodes (`EpoxyChronicleInstanceRole`) require `elasticfilesystem:*` and
  `fsx:DescribeFileSystems` IAM permissions for the destroy jobs to work. Add inline policy
  `burstlab-workloads-efs-lifecycle` to the compute node role.

---

## Approach B — Prolog/Epilog

Uses Slurm's `PrologSlurmctld` and `EpilogSlurmctld` hooks, which run on the head node
as `SlurmUser` before and after every job.

```bash
sbatch --comment=fsx:1200 --partition=aws myjob.sh
```

The prolog checks `SLURM_JOB_COMMENT`:
- `fsx:N` → creates FSx, waits for AVAILABLE, writes state file to `/opt/slurm/var/fsx-state/$USER/job-$ID.env`
- `efs`   → creates EFS, waits for available + mount target, writes state file to `/opt/slurm/var/efs-state/$USER/job-$ID.env`
- anything else → exit 0 immediately (zero cost for all other jobs)

> **Note:** `scontrol update JobId=N Environment=VAR=VAL` is not supported in Slurm 22.05
> (added in 23.02). The prolog writes state to a deterministic NFS path; the job script
> derives the path from `$SLURM_JOB_ID` instead of reading an injected env var.

Jobs without the trigger comment run without any overhead.

**Deploy:**
```bash
cd terraform/workloads/scenario4-prolog-epilog/
terraform init && terraform apply
# Deploys scripts to /opt/slurm/etc/scripts/
# Idempotently patches slurm.conf:
#   PrologSlurmctld=/opt/slurm/etc/scripts/storage-slurmctld-prolog.sh
#   EpilogSlurmctld=/opt/slurm/etc/scripts/storage-slurmctld-epilog.sh
#   PrologEpilogTimeout=1800
#   PrepPlugins=prep/script   ← REQUIRED in Slurm 22.05 for PrologSlurmctld to fire
# After patching, slurmctld must be RESTARTED (not just reconfigured) for
# PrepPlugins to take effect. The Terraform module runs scontrol reconfigure;
# restart slurmctld manually if PrologSlurmctld is not being called.
```

**Live testing notes (Gen 1, Slurm 22.05):**
- `SlurmUser` runs with PATH `/sbin:/bin:/usr/sbin:/usr/bin`. The prolog scripts prepend
  `/usr/local/bin` where the AWS CLI lives.
- `PrologSlurmctld`/`EpilogSlurmctld` are implemented via the PREP plugin framework in
  22.05. They are silently ignored unless `PrepPlugins=prep/script` is in slurm.conf.
  After adding this line, slurmctld must be **restarted** (not just reconfigured) to load
  the plugin.
- The state file is written to `/opt/slurm/var/{fsx,efs}-state/$USER/job-$ID.env` (NFS
  path, writable by `slurm` user, readable from all nodes). Home dirs (chmod 700) are not
  accessible to the `slurm` user.
- The job script uses `set -a; source "$STATE_FILE"; set +a` before `exec`ing the workload
  script — `set -a` is required so the sourced variables are exported into the child
  process (plain `source` only sets them in the current shell).
- The job should poll up to 30s for the state file (NFS attribute cache may briefly hide
  a file written by the prolog 0.1 seconds earlier on the head node).
- EFS: `efs_wait_available` must be called **before** `efs_add_mount_target` — EFS rejects
  `CreateMountTarget` while still in `creating` state (`IncorrectFileSystemLifeCycleState`).

**Coexistence:** If both scenario3-prolog-epilog and scenario4-prolog-epilog are applied,
they share a single combined `storage-slurmctld-prolog.sh` dispatcher that handles both
`fsx:` and `efs` comment prefixes. Slurm only allows one `PrologSlurmctld` line.

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

Does the cluster already have PrologSlurmctld configured?
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
