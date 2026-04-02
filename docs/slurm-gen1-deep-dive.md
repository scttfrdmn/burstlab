# Slurm Gen 1 Deep Dive: slurm.conf Explained

This is the document an SA shows a customer. Every directive in the BurstLab Gen 1 `slurm.conf` is explained — what it does, why this specific value was chosen, and what breaks if you get it wrong.

The full template lives at `configs/gen1-slurm2205-rocky8/slurm.conf.tpl`. What follows is that template, section by section, with full explanation.

---

## Cluster Identity

```ini
ClusterName=burstlab-gen1
SlurmctldHost=headnode(10.0.0.10)
```

**ClusterName** is a string that identifies this cluster to Slurm's accounting system (slurmdbd). It must be unique per slurmdbd instance. If you register two clusters with the same name against the same slurmdbd, accounting data collides. For BurstLab, the cluster name is passed in as a Terraform variable and templated here.

**SlurmctldHost** tells every node in the cluster where to find the Slurm controller daemon. The format `hostname(IP)` includes both the hostname and its private IP address. The IP address is the critical part for burst nodes — when a burst node boots in the cloud subnet, it needs to connect back to slurmctld before DNS has settled. Specifying the IP directly ensures the connection works immediately.

The TCU equivalent was `SlurmctldHost=hpccw01`. Their hpclogin node had a different `SlurmctldHost` value (possibly with a different hostname or missing the IP), which caused slurmd on the login node to connect to the wrong controller. Always use the format `hostname(IP)` and confirm it is identical on every node.

---

## Authentication

```ini
AuthType=auth/munge
CryptoType=crypto/munge
MpiDefault=none
```

**AuthType=auth/munge** means all Slurm inter-node communication is authenticated using MUNGE tokens. Munge is the de-facto standard for shared-secret authentication on HPC clusters. Every node that participates in the cluster must:

1. Have the `munge` daemon running
2. Share the **identical** `/etc/munge/munge.key`

How munge works: when `slurmctld` sends a message to `slurmd` on a compute node, it wraps the message in a munge token — a credential that encodes the sender's UID and timestamp, encrypted with the shared key. The receiving node decrypts the token using its own copy of the key and verifies the UID and timestamp. If either doesn't match (wrong key, expired token, clock skew > 5 minutes), authentication fails.

**What happens if munge fails:** slurmd on a compute or burst node refuses to register with slurmctld. In the logs you see:

```
slurmd: error: Munge encode failed: Authentication failure
```

Or on the controller:

```
slurmctld: error: _slurm_rpc_node_registration: Invalid authentication credential
```

**How munge key distribution works in BurstLab:** The head node generates a fresh munge key on first boot and copies it to `/opt/slurm/etc/munge/munge.key` on EFS. Compute nodes and burst nodes copy this file to `/etc/munge/munge.key` during their own cloud-init. Because all nodes read from the same EFS source, the key is guaranteed to be identical.

In real on-prem clusters, the munge key is typically distributed via Puppet, Ansible, or a shared NFS mount. The TCU problem was not a munge key issue — but munge key mismatch is the first thing to check when nodes refuse to register.

**CryptoType=crypto/munge** specifies the cryptographic plugin used for job credential signing. This is distinct from AuthType (which controls daemon authentication). Both use munge in this configuration.

**MpiDefault=none** disables a default MPI library binding. For a demo cluster, none is correct. If you are running real parallel MPI jobs, you would set this to `pmi2` or `pmix`.

---

## Process and Task Tracking

```ini
ProctrackType=proctrack/cgroup
TaskPlugin=task/affinity,task/cgroup
```

**ProctrackType=proctrack/cgroup** uses Linux cgroups to track processes within a job. This is required for `ConstrainRAMSpace=yes` in `cgroup.conf` to work — without cgroup tracking, Slurm cannot enforce memory limits.

**TaskPlugin=task/affinity,task/cgroup** enables CPU affinity binding (jobs are pinned to their allocated cores) and cgroup-based resource enforcement. Both require `cgroup.conf` to be present on every node at the same path.

The `cgroup.conf` in BurstLab is minimal but correct for CentOS 8 (cgroup v1):

```ini
CgroupAutomount=yes
CgroupMountpoint=/sys/fs/cgroup
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainSwapSpace=no
```

`ConstrainRAMSpace=yes` is important: without it, a job requesting 4GB can OOM-kill the node. With it, the job gets an OOM kill of its own process instead. For a shared cluster, this is critical. The swap constraint is disabled to avoid instant OOM kills during job startup before the working set is known.

---

## SelectType and Resource Tracking

```ini
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
```

**SelectType=select/cons_tres** (Consumable Resources with Trackable RESources) is the scheduler's resource allocation plugin. With `cons_tres`, Slurm tracks individual cores, memory, and other resources (GPUs, network) as consumable — once allocated to a job, they are not available to other jobs until released.

The alternative, `select/linear`, allocates entire nodes at a time. Linear was common in older Slurm versions and some distributions still default to it.

**Why this matters for cloud bursting:** Plugin v2 uses the node's resource specs (`CPUs`, `RealMemory`, `Gres`) from `slurm.conf` to size EC2 instances correctly. `cons_tres` with `CR_Core_Memory` ensures that both CPU and memory are tracked, which in turn ensures `RealMemory` values in node definitions are enforced. This affects which jobs get scheduled to burst nodes and how many jobs pack onto a single burst instance.

**Why it matters for cloud billing:** A mismatched `SelectType` or wrong `SelectTypeParameters` can cause jobs to over-allocate burst nodes. If `SelectTypeParameters=CR_Core` (no memory tracking), a job requesting 4 CPUs and 8GB on a 4-CPU burst node could still run even if another job already consumed 7GB of that node's memory — you end up with OOM kills on expensive burst instances.

**The TCU problem:** TCU's `SelectType` was set differently between their head node and login node configs. This is a silent divergence — slurm.conf accepts `SelectType` mismatches across node types without logging an obvious error, but the scheduler's behavior becomes undefined. `cons_tres` with `CR_Core_Memory` must be identical on every node.

---

## Accounting (slurmdbd)

```ini
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=headnode
AccountingStoragePort=6819
AccountingStoreTRES=gres/gpu
AccountingStorageEnforce=associations,limits
```

**AccountingStorageType=accounting_storage/slurmdbd** tells slurmctld to record job data in a remote database via the Slurm Database Daemon (slurmdbd). This is required for Plugin v2 to function.

**Why slurmdbd is required for Plugin v2:** The plugin tracks the lifecycle of burst nodes — when they were launched, when they registered, when they became idle, when they were suspended. This state tracking relies on job accounting records in slurmdbd. Without it, the plugin cannot reliably detect when a burst node has been idle long enough to trigger `SuspendProgram`.

If `slurmctld` starts without a working slurmdbd connection, it enters a degraded state — cloud bursting will appear to work but nodes may fail to power down correctly or may enter error states that require manual intervention.

**AccountingStorageEnforce=associations,limits** means jobs submitted by users who are not registered in the accounting database will be rejected. For a lab cluster, this requires that you have at minimum a root-level account and the `alice` user associated with it. The head node cloud-init script runs:

```bash
sacctmgr -i add cluster burstlab-gen1
sacctmgr -i add account default Description="Default account" Organization="BurstLab"
sacctmgr -i add user root account=default
sacctmgr -i add user alice account=default
```

**slurmdbd.conf** is a separate configuration file (`configs/gen1-slurm2205-rocky8/slurmdbd.conf.tpl`). Key points:
- Must be owned by `slurm:slurm` with mode `0600` — slurmdbd refuses to start if permissions are wrong
- `StorageType=accounting_storage/mysql` — slurmdbd uses MariaDB on the head node
- `StoragePass` is substituted at deploy time from a Terraform-generated random password

---

## Logging

```ini
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
SlurmctldDebug=info
SlurmdDebug=info
```

Log files at `/var/log/slurm/` are the first place to look when anything goes wrong. The `info` debug level is appropriate for a learning environment — it is verbose enough to see what Slurm is doing (node state transitions, job scheduling decisions, plugin calls) without being overwhelming.

For debugging burst issues specifically, temporarily increase to `debug` or `debug2`:

```bash
scontrol setdebug debug2
# Reproduce the issue
scontrol setdebug info  # reset when done
```

Plugin v2 logs separately to the path configured in `config.json`:

```
/var/log/slurm/aws_plugin.log
```

---

## Power Save / Cloud Bursting

This is the core section. Every directive here directly affects burst node behavior.

### PrivateData=CLOUD

```ini
PrivateData=CLOUD
```

This directive controls what `sinfo` shows to non-privileged users. Without `PrivateData=CLOUD`, cloud nodes in the `CLOUD` (powered off) state are hidden from `sinfo` output by default. Users and SAs would see an empty aws partition and have no visibility into the burst node inventory.

With `PrivateData=CLOUD`, cloud nodes are always visible in `sinfo`, regardless of their state:

```bash
# Without PrivateData=CLOUD:
$ sinfo -p aws
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
aws          up    4:00:00      0   idle

# With PrivateData=CLOUD:
$ sinfo -p aws
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
aws          up    4:00:00      8  idle~  aws-burst-[0-7]
```

This is a demo-critical directive. An SA showing a customer "your burst capacity" needs to be able to point at nodes in `cloud~` state. Without it, the partition looks empty and the demo falls flat.

`PrivateData=CLOUD` also affects `scontrol show nodes` — cloud nodes show their full configuration including CPU and memory specs even when powered off.

### ResumeProgram and SuspendProgram

```ini
ResumeProgram=/opt/slurm/etc/aws/resume.py
SuspendProgram=/opt/slurm/etc/aws/suspend.py
```

These are the integration points between Slurm's power-saving framework and Plugin v2.

**ResumeProgram** is called by slurmctld when a job is submitted to the aws partition and there are no available nodes. Slurm passes the node name(s) as an argument. `resume.py` translates the node names into an EC2 `CreateFleet` request:

1. Parses the node names (e.g., `aws-burst-[0-2]`)
2. Looks up the corresponding partition and node group in `partitions.json`
3. Calls `ec2:CreateFleet` with the launch template, instance type overrides, and subnet IDs
4. Sets the `Name` tag on new instances to the Slurm node name (e.g., `aws-burst-0`)
5. Records the launch in the Plugin v2 state database

The burst nodes read their `Name` tag via IMDS to set `SLURM_NODENAME`, which determines the hostname they register with. If the tag does not match a name in `slurm.conf`, slurmd will not register correctly.

**SuspendProgram** is called by slurmctld after a node has been idle for `SuspendTime` seconds. `suspend.py` calls `ec2:TerminateInstances` for the corresponding EC2 instances and marks the nodes as `CLOUD` (powered off) in Slurm.

Both scripts run as the `slurm` user, which is why the head node's IAM instance profile needs EC2 Fleet and TerminateInstances permissions — those API calls are made under the head node's IAM role.

### ResumeRate and SuspendRate

```ini
ResumeRate=100
SuspendRate=100
```

These control how many nodes Slurm will resume or suspend per clock cycle (default: 60 seconds). `0` means unlimited. `100` means up to 100 nodes per cycle.

For a demo cluster with 10 burst nodes, `100` is effectively unlimited. The reason to use a non-zero value in production is to avoid flooding EC2 with `CreateFleet` calls during a burst storm — e.g., 500 jobs submitted simultaneously each requesting a new node. Rate-limiting gives EC2 time to process earlier requests before more are queued.

For BurstLab, `100` means all demo burst nodes (10) can be launched in a single cycle, which makes the demo feel snappy.

### ResumeTimeout

```ini
ResumeTimeout=300
```

After `ResumeProgram` is called, Slurm waits up to `ResumeTimeout` seconds for the node to transition from `CLOUD*` (resuming) to `IDLE`. If the node does not register within this window, Slurm marks it `DOWN*` with reason `Not responding`.

**What to set this to:** On `m7a.2xlarge`, the sequence from `CreateFleet` call to `slurmd` registration is:
- EC2 instance starts: ~30-60 seconds
- Cloud-init runs (mount EFS, copy munge key, start slurmd): ~30-60 seconds
- Total: 60-120 seconds typical, 180 seconds worst case

`ResumeTimeout=300` gives 5 minutes — ample margin for the typical 90-120 second startup. Setting it too low (e.g., `60`) causes burst nodes to go `DOWN*` before they finish starting, which breaks the demo. Setting it too high (e.g., `600`) means real failures (IAM issue, instance never launched) take a long time to surface.

**What the SA sees when ResumeTimeout is too short:**

```bash
$ sinfo -p aws
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
aws          up    4:00:00      1  down*  aws-burst-0

$ scontrol show node aws-burst-0 | grep Reason
   Reason=Not responding [slurm@2025-03-26T10:15:00]
```

**Recovery:** If a node goes `DOWN*` but you know it is actually running:

```bash
scontrol update nodename=aws-burst-0 state=resume
```

This only works if `ReturnToService=2` is set (see below).

### SuspendTime

```ini
SuspendTime=350
```

After a burst node has been idle for `SuspendTime` seconds with no running jobs, `SuspendProgram` is called to terminate it.

**The relationship with ResumeTimeout:** `SuspendTime` must be greater than `ResumeTimeout`. If `SuspendTime < ResumeTimeout`, a pathological loop is possible:

1. Job submitted → node resumes (CreateFleet called)
2. Node is still starting (within ResumeTimeout window)
3. SuspendTime expires before the node registers
4. SuspendProgram is called, terminating the instance
5. Slurm tries to resume again for the still-pending job
6. Loop repeats

The relationship `SuspendTime = ResumeTimeout + buffer` is documented in the Slurm power save guide. BurstLab uses `SuspendTime=350` = `ResumeTimeout=300` + 50 seconds buffer.

For a demo, 350 seconds (about 6 minutes) is slightly long — after a demo job finishes, you wait 6 minutes before the burst node terminates. This is configurable. For a faster demo teardown you could reduce to `SuspendTime=320`. Do not go below `ResumeTimeout + 10`.

### TreeWidth

```ini
TreeWidth=60000
```

`TreeWidth` controls the fan-out of Slurm's inter-node message tree. By default (50), slurmctld fans out messages to 50 nodes at a time, which then forward to 50 more, etc. In a cluster with 10,000 nodes this is necessary to avoid overwhelming the controller.

For a cloud-burst cluster where `slurmctld` needs to send a "start slurmd" message directly to burst nodes that just came online, the tree-based forwarding can introduce delays — you want direct fan-out. `TreeWidth=60000` is larger than any realistic BurstLab cluster, so slurmctld communicates directly with all nodes simultaneously.

In very large clusters (> 50,000 nodes), you would tune this down. For any BurstLab cluster or realistic HPC environment, `60000` is correct.

### ReturnToService

```ini
ReturnToService=2
```

This controls what happens when a node transitions to `DOWN` state and then recovers:

| Value | Behavior |
|---|---|
| `0` | Node stays DOWN even after recovery. Requires `scontrol update node=X state=resume` manually. |
| `1` | Node automatically returns to service if it went DOWN for no specific reason (i.e., not due to a hardware failure reason). |
| `2` | Node always returns to service when it re-registers with slurmctld, regardless of reason. |

For cloud bursting, `ReturnToService=2` is required. When a burst node terminates and is later relaunched by `resume.py`, the new instance may have a different private IP. Slurm might have marked the previous instance `DOWN` due to lost connectivity. With `ReturnToService=2`, the new instance registers cleanly and the node goes `IDLE`.

Without `ReturnToService=2`, any transient failure (network hiccup during registration, ResumeTimeout exceeded by a slow boot) permanently disables the burst node until manual intervention. In a demo environment, this means a failed first burst attempt permanently breaks cloud bursting for that node name until an SA runs `scontrol` commands.

### DebugFlags=NO_CONF_HASH

```ini
DebugFlags=NO_CONF_HASH
```

This is the most important directive for cloud bursting with a shared EFS config. Understanding it requires understanding the TCU problem.

**The TCU problem (hpclogin vs hpccw01):**

TCU ran two nodes that both participated in the Slurm cluster: `hpccw01` (the controller, running `slurmctld`) and `hpclogin` (a login node, running `slurmd`). Over time, their `slurm.conf` files had diverged — directives were added or changed on one node but not the other. This is the most common Slurm configuration failure mode at HPC sites.

When slurmctld starts, it computes a hash of its running `slurm.conf`. When any `slurmd` connects, it sends its own hash of its local `slurm.conf`. If the hashes differ, `slurm` refuses the connection:

```
slurmd: error: Connection with slurmctld failed: Invalid configuration
```

Or the controller rejects the node:

```
slurmctld: error: validate_slurm_user: Slurm config hash mismatch with node hpclogin
```

**The BurstLab EFS solution — and why NO_CONF_HASH is still needed:**

BurstLab's solution is that all nodes share a single `slurm.conf` via EFS. There is only one file — config divergence is architecturally impossible. So why do we still need `DebugFlags=NO_CONF_HASH`?

**Timing.** `slurmctld` starts on the head node and computes its config hash. Burst nodes do not exist yet when `slurmctld` starts. When a burst node launches later and mounts EFS, it reads the current `slurm.conf` from EFS. But the hash that `slurmctld` computed at startup included values (like the burst node stanza generated by `generate_conf.py`) that were appended to `slurm.conf` after `slurmctld` was already running.

More specifically: `generate_conf.py` is run after `slurmctld` starts, and its output is appended to `slurm.conf`. The hash is stale. The next time `slurmctld` reloads (e.g., `scontrol reconfig`), it updates the hash — but during the window between appending the burst node config and the next reload, hash verification would fail for burst nodes.

`DebugFlags=NO_CONF_HASH` disables hash verification entirely. This is the documented approach for clusters where nodes may have configuration that varies from what was loaded at controller startup. It is safe — the "security" that hash checking provides is against misconfiguration, not against adversarial attacks. In an environment where you control `slurm.conf` via EFS or a config management system, hash checking is redundant.

---

## Compute Node Definitions

```ini
NodeName=compute[01-04] CPUs=8 RealMemory=31500 State=IDLE
PartitionName=local Nodes=compute[01-04] Default=YES MaxTime=INFINITE State=UP
```

**NodeName=compute[01-04]** defines the four static compute nodes. The bracket notation is Slurm's range syntax — it expands to `compute01`, `compute02`, `compute03`, `compute04`.

**CPUs=8** matches the vCPU count of the `m7a.2xlarge` instance type (8 vCPUs). Setting this correctly is important for job packing — if you declare more CPUs than the node has, Slurm will over-allocate, causing jobs to compete for the same physical cores.

**RealMemory=31500** is the usable memory in MB. `m7a.2xlarge` has 32 GB = 32768 MB. We deduct ~1268 MB for the OS, munge, slurmd, and system overhead. Setting `RealMemory` too high causes jobs to request more memory than the node can actually provide, leading to OOM kills that are difficult to diagnose.

**State=IDLE** means the node starts in the ready state. No boot or resume operation is needed — the instance is always running.

**PartitionName=local ... Default=YES** makes the local partition the default. A job submitted without `--partition` lands here, on the always-available static compute nodes. This is the expected behavior for a cluster where the local partition represents the "campus allocation" and cloud bursting is opt-in.

---

## Burst Node Definitions

The burst node stanza in `slurm.conf` is generated by `generate_conf.py` (from Plugin v2) and appended to the file:

```ini
NodeName=aws-burst-[0-7] CPUs=8 RealMemory=31500 Weight=1 State=CLOUD
PartitionName=aws Nodes=aws-burst-[0-7] Default=NO MaxTime=4:00:00 State=UP
```

**State=CLOUD** is the Slurm state for powered-off burst nodes. Nodes in `CLOUD` state are not expected to be running — slurmctld knows it needs to call `ResumeProgram` before sending any jobs to them. Without `State=CLOUD`, Slurm would treat missing burst nodes as `DOWN` and take them out of service immediately.

**Weight=1** affects node selection in partitions that span both local and burst nodes (the optional `all` partition). Higher weight = lower priority for scheduling. With compute nodes at the default weight (0) and burst nodes at weight 1, Slurm prefers compute nodes for jobs that can run on either. This is the correct behavior: use local capacity first, burst only when local is full.

**MaxTime=4:00:00** caps job runtime on burst nodes at 4 hours. This is a cost control measure — a job that runs indefinitely on an `m7a.2xlarge` would accumulate unexpected charges. 4 hours is long enough for most demo and research computing jobs, short enough to prevent runaway costs.

**PartitionName=aws ... Default=NO** makes the aws partition non-default. Users must explicitly request `--partition=aws` to burst. This matches typical HPC policy: bursting is an opt-in resource, not the default allocation.

**Node naming convention:** `aws-burst-[0-7]` follows Plugin v2's naming scheme: `{PartitionName}-{NodeGroupName}-{index}`. With `PartitionName=aws` and `NodeGroupName=burst` in `partitions.json`, the names are `aws-burst-0` through `aws-burst-N`. This naming is not optional — the names must match exactly between `slurm.conf` (node definitions), `partitions.json` (plugin config), and the EC2 `Name` tag set by `resume.py`.

---

## Partition Weight and Hybrid Scheduling

An optional `all` partition can span both local and cloud nodes:

```ini
PartitionName=all Nodes=compute[01-04],aws-burst-[0-7] Default=NO MaxTime=INFINITE State=UP
```

With `Weight=1` on burst nodes and default weight on compute nodes, jobs submitted to `--partition=all` will preferentially land on local compute nodes. When local nodes are full, the scheduler automatically overflows to burst nodes. This is the "cloud bursting" behavior from a user perspective — they submit to `all` and the cluster handles allocation.

For a demo, having both `local`, `aws`, and `all` partitions lets an SA show different scenarios:
- `--partition=local`: always on-prem, guaranteed immediate execution (up to capacity)
- `--partition=aws`: always a burst node (for showing the cloud transition)
- `--partition=all`: hybrid overflow (for showing automatic bursting)

---

## Common slurm.conf Errors

**"slurmctld won't start — log shows 'unable to open file /opt/slurm/etc/slurm.conf'"**
The `SLURM_CONF` environment variable is not set or points to the wrong path. Check the systemd unit file: `systemctl cat slurmctld | grep SLURM_CONF`.

**"slurmd says 'Invalid authentication credential'"**
Munge key mismatch. Run `munge -n | ssh computeX unmunge` from the head node to verify round-trip auth. If it fails, copy the key: `scp /etc/munge/munge.key computeX:/etc/munge/munge.key` and restart munge on that node.

**"slurmctld starts but immediately shows all compute nodes as DOWN"**
The `SlurmdTimeout` (300 seconds by default) may have been reached before compute nodes finished their cloud-init. Run `scontrol update nodename=compute[01-04] state=resume` to bring them back. Also check that `slurmd` is running on the compute nodes: `systemctl status slurmd`.

**"serializer/json plugin not found" in slurmctld log**
This is a known issue in some Slurm 22.05 patch levels. The JSON serializer plugin (`serializer_json.so`) is required for accounting and may be absent if the build was configured without JSON support. The BurstLab Packer build compiles Slurm with all plugins enabled, so this should not occur with BurstLab AMIs. If you see it on a customer cluster, the fix is to rebuild Slurm with `--with-json` or install the `slurm-serializer` package. This is exactly the problem that blocked `slurmctld` from starting at TCU.

---

## Cross-References

- Plugin v2 `config.json` and `partitions.json` — how these values map: [plugin-v2-setup.md](plugin-v2-setup.md)
- Network and IAM context for burst nodes: [architecture.md](architecture.md)
- Deploy steps: [quickstart.md](quickstart.md)
