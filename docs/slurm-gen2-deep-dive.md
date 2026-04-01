# BurstLab Gen 2 Deep Dive
## Rocky Linux 9 + Slurm 23.11.x + AWS Plugin for Slurm v2

This document explains every configuration decision that differs from Gen 1
(Rocky 8 + Slurm 22.05). Read [slurm-gen1-deep-dive.md](slurm-gen1-deep-dive.md) first —
Gen 2 is a delta, not a from-scratch explanation.

---

## What Changed: OS — Rocky Linux 8 → Rocky Linux 9

Rocky Linux 9 is the RHEL 9 community rebuild. From a Slurm cluster perspective, three
things differ operationally from Rocky 8.

### 1. Package repo: `powertools` → `crb`

On Rocky 8, the extra-packages repo providing `-devel` packages is called `powertools`:
```
dnf config-manager --set-enabled powertools
```

On Rocky 9, Red Hat renamed it to **CRB** (CodeReady Linux Builder):
```
dnf config-manager --set-enabled crb
```

The Packer template (`ami/rocky9-slurm2311.pkr.hcl`) handles this. If you see
`Error: No match for argument: munge-devel` during a Packer build, CRB is not enabled.

### 2. Python: no module shim needed

Rocky 8's default Python 3.6 lacked pip's boto3 because `boto3` requires Python 3.7+
and Rocky 8 only ships 3.6 in the base OS. The Gen 1 solution was to install `python38`
via a DNF module and create a `/usr/local/bin/python3` wrapper script.

Rocky 9 ships **Python 3.9** as the default `python3`. boto3 installs cleanly:
```bash
pip3 install boto3
```

No wrapper is needed. The plugin scripts use `#!/usr/bin/env python3` (which resolves
to `/usr/bin/python3` = Python 3.9 with boto3). The `head-node-init.sh.tpl` shebang
patch is gated on `VERSION_ID=8` and skips cleanly on Rocky 9.

### 3. cgroup hierarchy: v2 only on EC2

Rocky Linux 9 EC2 AMIs (and RHEL 9 in general) use **cgroup v2 exclusively**. The legacy
cgroup v1 hierarchy is not present — there is no `/sys/fs/cgroup/cpu`, `/sys/fs/cgroup/freezer`,
etc. Only the unified v2 hierarchy at `/sys/fs/cgroup` is mounted.

Gen 2 uses `CgroupPlugin=cgroup/v2` in `cgroup.conf`. This is required on Rocky 9 EC2;
using `cgroup/v1` causes slurmd to fail at startup with:
```
error: cgroup namespace 'freezer' not mounted. aborting
error: cannot create proctrack context for proctrack/cgroup
error: slurmd initialization failed
```

**Build note:** The cgroup/v2 plugin has two compile-time dependencies not in base CRB:
- `dbus-devel` — D-Bus headers for systemd cgroup v2 management
- `kernel-headers` — eBPF headers for device constraints (`include/linux/bpf.h`)

Without these, `configure` silently skips the `cgroup/v2` plugin and only builds `cgroup/v1`.
The Gen 2 Packer AMI installs both before building Slurm.

**Also removed in Slurm 23.11:** `CgroupAutomount` is a defunct parameter. If present in
`cgroup.conf`, slurmd exits with an error. Do not include it. `CgroupMountpoint` was also
removed for the v2 plugin (it has a single unified mount at `/sys/fs/cgroup`).

To verify on a running Gen 2 node:
```bash
mount | grep cgroup
# Should show ONLY: cgroup2 on /sys/fs/cgroup type cgroup2 (...)
# No "type cgroup " (v1) entries

# Slurm's cgroup v2 tree:
ls /sys/fs/cgroup/system.slice/ | grep slurm
```

---

## What Changed: Slurm 22.05 → 23.11

### `SlurmctldParameters=idle_on_node_suspend`

**This is the most visible Gen 2 change** — it affects what every user sees in `sinfo`.

In Slurm 22.05 and Gen 1, a powered-down cloud node shows as `idle~` in sinfo:
```
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
local*       up   infinite      4  idle  compute[01-04]
aws          up    4:00:00      8  idle~ aws-burst-[0-7]
```

The `~` suffix means "idle, but in power-save state." Every SA demo prompted the question:
*"What does the tilde mean?"* The explanation — cloud nodes are powered down and will boot
on demand — is correct, but the notation is non-intuitive and distracts from the demo.

In Slurm 23.11 with `SlurmctldParameters=idle_on_node_suspend`, powered-down cloud nodes
show as plain `idle`:
```
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
local*       up   infinite      4  idle  compute[01-04]
aws          up    4:00:00      8  idle  aws-burst-[0-7]
```

The node is still powered down. The only difference is the display. When a job is submitted to
the `aws` partition, Slurm still calls `ResumeProgram` to boot the node.

**When to mention this in a demo:** After the first `sinfo`, say: *"Unlike our on-prem cluster
where DOWN means broken, cloud nodes show idle because they're ready — they just need to boot.
When you submit a job here, Slurm calls our resume script and the instance spins up."*

### `TaskPlugin=task/cgroup` (dropped `task/affinity`)

Gen 1 used `TaskPlugin=task/affinity,task/cgroup`. Gen 2 uses only `task/cgroup`.

`task/affinity` provides CPU pinning via Linux scheduler affinity masks — useful for MPI
workloads that care about NUMA locality. `task/cgroup` provides CPU, memory, and device
isolation using the cgroup hierarchy.

For the BurstLab demo workload (hostname, nproc, sleep), neither makes a practical difference.
Dropping `task/affinity` simplifies the configuration and reflects the 23.11 recommendation
that `task/cgroup` alone is sufficient for most clusters. Sites with latency-sensitive MPI
workloads can add it back.

### `slurmrestd` — REST API daemon (new in AMI)

The Gen 2 Packer build adds `--enable-slurmrestd` to the Slurm configure flags. The
`slurmrestd.service` unit is written to `/etc/systemd/system/slurmrestd.service` but NOT
enabled by default. The head-node-init script does not start it automatically.

To start `slurmrestd` manually for a demo:
```bash
# On the head node, as root or slurm:
systemctl start slurmrestd

# Verify it's listening on a Unix socket:
ls -la /var/spool/slurm/ctld/slurmrestd.socket 2>/dev/null || \
  journalctl -u slurmrestd --no-pager -n 20
```

Query the REST API (example — list all nodes):
```bash
curl -s --unix-socket /var/spool/slurm/ctld/slurmrestd.socket \
  http://localhost/slurm/v0.0.38/nodes | python3 -m json.tool | head -40
```

The API spec is at `/slurm/v0.0.38/openapi.json`. It exposes jobs, nodes, partitions,
reservations, and accounting data. Useful for demonstrating programmatic cluster access.

### Power save timing: unchanged (600s / 650s)

`ResumeTimeout=600` and `SuspendTime=650` are kept from the Gen 1 final values. These were
chosen after observing a real burst node take 302s to register slurmd (just over the original
300s timeout). 600s gives comfortable headroom.

### Plugin v2 protocol: unchanged

The `partitions.json` and `config.json` formats, and the `resume.py` / `suspend.py` /
`change_state.py` flow are identical to Gen 1. The `plugin-v2-setup.md` guide applies
without modification.

---

## `plugin_config.json` — ResumeTimeout/SuspendTime fixed

Gen 1's `plugin_config.json.tpl` had a latent mismatch: `ResumeTimeout=300, SuspendTime=350`
in config.json but 600/650 in slurm.conf. `common.py` validates these match at startup and
logs a warning if they diverge. Gen 2 corrects this: config.json and slurm.conf both use
600/650. Gen 3 inherits the fix.

---

## What Is Identical to Gen 1

| Component | Same? | Notes |
|-----------|-------|-------|
| Six Terraform modules | ✓ | vpc, iam, shared-storage, head-node, compute-nodes, burst-config |
| UserData init scripts | ✓ | Shared; OS detection handles Rocky 8 vs 9 differences |
| EFS mount strategy | ✓ | Plain NFSv4.1; same fstab options |
| Munge auth | ✓ | Same key distribution via base64 in UserData |
| Slurm accounting | ✓ | MariaDB + slurmdbd; alice and root in default account |
| NAT setup | ✓ | iptables MASQUERADE; burstlab-nat.service for persistence |
| Plugin v2 | ✓ | Same branch, same scripts, same config.json schema |
| validate-cluster.sh | ✓ | All checks apply; shebang check updated to boto3-import test |
| demo-burst.sh | ✓ | Unchanged; alice user guard and simplified --wrap in place |

---

## Building and Deploying Gen 2

```bash
# 1. Build the AMI (takes ~20 minutes)
cd /path/to/burstlab
AWS_PROFILE=aws packer build ami/rocky9-slurm2311.pkr.hcl

# 2. Find the AMI ID
AWS_PROFILE=aws aws ec2 describe-images --owners self \
  --filters 'Name=name,Values=burstlab-gen2-*' \
  --query 'sort_by(Images, &CreationDate)[-1].{ID:ImageId,Name:Name}' \
  --output table

# 3. Deploy
cd terraform/generations/gen2-slurm2311-rocky9
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set key_name and head_node_ami
terraform init
terraform apply

# 4. SSH to head node
ssh -i ~/.ssh/<key>.pem rocky@$(terraform output -raw head_node_public_ip)

# 5. Validate
bash /opt/slurm/etc/validate-cluster.sh

# 6. Demo
su - alice
bash /opt/slurm/etc/demo-burst.sh
```

---

## Troubleshooting Gen 2-Specific Issues

**`sinfo` shows `idle` but jobs sit pending:**
- Same as Gen 1: check `squeue -j <jobid>` for reason. If `Resources` or `Priority`,
  nodes are booting. Watch `sinfo -i5`.
- If `InvalidQOS` or account error: check `sacctmgr show user alice`.

**boto3 not found (`ModuleNotFoundError: No module named 'boto3'`):**
- Rocky 9: system Python 3.9 should have boto3 from the AMI build.
- Check: `python3 -c "import boto3; print(boto3.__version__)"`
- Fix: `sudo pip3 install boto3 --break-system-packages`

**CRB packages missing during custom AMI builds:**
- `sudo dnf config-manager --set-enabled crb && sudo dnf makecache`
- If `config-manager` is unavailable: `sudo dnf install -y 'dnf-command(config-manager)'`

**cgroup/v1 not found at runtime:**
- Rocky 9 should have v1 mounted. Check: `mount | grep "type cgroup "`
- If missing (some container environments don't expose v1): change `CgroupPlugin=cgroup/v2`
  in `cgroup.conf` and restart slurmd on affected nodes.
