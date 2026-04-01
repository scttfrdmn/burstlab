# Slurm: A Five-Minute Introduction

Slurm is the job scheduler running on most university HPC clusters. You submit work to it, it decides when and where to run it, and it handles the bookkeeping. This document covers the concepts and commands you need to understand BurstLab.

For a quick command reference, bookmark the official cheat sheet: https://slurm.schedmd.com/pdfs/summary.pdf

---

## The Big Picture

A Slurm cluster has two kinds of nodes:

- **Head node** (also called the controller): runs `slurmctld`, the brain of the scheduler. You log into this node to submit jobs. It never runs your actual computations.
- **Compute nodes**: run `slurmd`, the worker. When a job is assigned here, slurmd launches your code.

In BurstLab there is a third kind:

- **Burst nodes**: compute nodes that don't exist yet. When a burst job is submitted, Slurm launches an EC2 instance, waits for it to register, and then sends the job there. When idle long enough, the instance terminates.

---

## Jobs

A **job** is a unit of work you submit to the scheduler. At minimum, it has:
- The command to run
- Resource requirements (CPUs, memory, time limit)
- A partition to run in

Slurm queues jobs and runs them when resources are available. You never SSH into a compute node and run things by hand — the scheduler handles placement.

### Submitting jobs

```bash
# Run a command (quick way — good for testing)
sbatch --wrap="hostname && date"

# Run a script
sbatch my-job.sh

# Specify resources explicitly
sbatch --partition=cloud --cpus-per-task=4 --mem=8G --time=1:00:00 my-job.sh
```

The output of `sbatch` is a job ID:
```
Submitted batch job 42
```

### Job scripts

For real work, write a shell script with `#SBATCH` directives at the top:

```bash
#!/bin/bash
#SBATCH --job-name=my-analysis
#SBATCH --partition=local
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=2:00:00
#SBATCH --output=%j.out    # %j is the job ID

echo "Running on: $(hostname)"
echo "CPUs available: $(nproc)"
# ... your actual work here
```

Submit it with `sbatch my-job.sh`.

### Watching your jobs

```bash
squeue                     # all jobs in the queue
squeue --me                # only your jobs
squeue -j 42               # specific job
squeue --format="%.8i %.12j %.10P %.8T %.6D %.12l %.12N"  # more detail
```

**Job states:**
- `PD` — Pending (waiting for resources)
- `R` — Running
- `CG` — Completing
- `F` — Failed

If your job is pending, `scontrol show job 42` will tell you why (look for `Reason=`).

### Cancelling jobs

```bash
scancel 42          # cancel job 42
scancel --me        # cancel all your jobs
scancel -p cloud    # cancel all cloud partition jobs
```

---

## Partitions

A **partition** is a named group of nodes with shared scheduling policies. Think of it as a queue with rules.

```bash
sinfo              # show all partitions and their node states
sinfo -p local     # show only the 'local' partition
```

In BurstLab:
- `local` — always-on compute nodes; jobs run immediately; no time limit
- `cloud` — burst nodes; jobs trigger EC2 launches; 4-hour time limit

The `*` in `sinfo` output marks the default partition (where jobs go if you don't specify `--partition`).

---

## Node States

`sinfo` shows each node's state:

| State | Meaning |
|-------|---------|
| `idle` | Available, no jobs |
| `alloc` | Running one or more jobs |
| `down` | Not available (check `scontrol show node`) |
| `drain` | Being taken offline (jobs finish, no new ones start) |
| `idle~` | Powered off (cloud node, no EC2 instance) |
| `alloc~` | Powering on — job assigned, instance launching |
| `cloud` | Registered but explicitly powered-off state |

The `~` suffix means the node is in power-saving mode (no EC2 instance running).

---

## Accounts and Users

Slurm has an accounting system (`slurmdbd`) that tracks who ran what, when, and how much resource they used. Every user must belong to an account before they can submit jobs.

```bash
sacctmgr show user         # list all registered users
sacctmgr show account      # list all accounts
sacctmgr show cluster      # show the cluster name
```

In BurstLab, `alice` is pre-registered in the `default` account. If you add a new user, register them:

```bash
sacctmgr add user newuser account=default
```

---

## Checking Cluster Health

```bash
sinfo                              # partition and node summary
scontrol show nodes                # detailed node info
scontrol show node compute01       # one specific node
scontrol show config | grep -i resume   # check burst config
sacctmgr show cluster              # confirm accounting is working
```

---

## Common Patterns

### Fill the local partition, then burst

```bash
# Submit 8 jobs that each use all CPUs on one node
for i in $(seq 1 8); do
  sbatch --partition=local --cpus-per-task=8 --wrap="sleep 60"
done

# Submit 4 more — these will burst to cloud nodes
for i in $(seq 1 4); do
  sbatch --partition=cloud --cpus-per-task=8 --wrap="sleep 60"
done

watch -n5 sinfo   # watch nodes come and go
```

### Check why a job is pending

```bash
scontrol show job <jobid>
# Look for: Reason=
# Common reasons:
#   Resources     — waiting for a node to free up
#   Priority      — higher priority jobs ahead of you
#   ReqNodeNotAvail — specific node requested is not available
#   BeginTime     — job has a --begin time in the future
```

### Run an interactive job (SSH-like but through Slurm)

```bash
srun --partition=local --pty bash
# You are now on a compute node in an interactive shell
hostname    # compute01
exit        # release the node
```

---

## What Happens When You Submit a Burst Job

1. You run `sbatch --partition=cloud ...`
2. Slurm marks the job `PD` (pending) and picks a cloud node to allocate
3. Slurm calls `resume.py` (the Plugin v2 ResumeProgram) with the node name
4. `resume.py` calls the EC2 `CreateFleet` API to launch an instance
5. The instance boots, runs cloud-init, starts `slurmd`
6. `slurmd` registers with `slurmctld` on the head node
7. Slurm transitions the job from `PD` to `R` and sends it to the burst node
8. Job runs. When it finishes, the node goes `idle~`
9. After `SuspendTime` seconds with no new jobs, Slurm calls `suspend.py`
10. `suspend.py` calls EC2 `TerminateInstances` — the node disappears

Total time from submit to running: **~90-120 seconds** for an m7a.2xlarge.
