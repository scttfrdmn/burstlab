# BurstLab Gen 3 Deep Dive
## Rocky Linux 10 + Slurm 24.05.x + AWS Plugin for Slurm v2

This document explains every configuration decision that differs from Gen 2
(Rocky 9 + Slurm 23.11). Read [slurm-gen2-deep-dive.md](slurm-gen2-deep-dive.md) first.

---

## What Changed: OS — Rocky Linux 9 → Rocky Linux 10

Rocky Linux 10 is the RHEL 10 community rebuild. RHEL 10 made two breaking changes relevant
to Slurm clusters: cgroup v1 removal and iptables-services removal.

### 1. cgroup v2 only — no v1

Rocky 10 (RHEL 10) compiles the kernel without `CONFIG_CGROUP_V1=y`. The legacy cgroup v1
hierarchy does not exist at `/sys/fs/cgroup/cpu`, `/sys/fs/cgroup/memory`, etc. Only the
unified cgroup v2 hierarchy at `/sys/fs/cgroup` is available.

**Impact on Slurm:** `CgroupPlugin=cgroup/v1` in `cgroup.conf` would cause every slurmd to
fail at startup with `error: cgroup namespace not found`. Gen 3 uses:

```
CgroupPlugin=cgroup/v2
```

**cgroup v2 operational differences:**
- Memory accounting includes swap by default → `ConstrainSwapSpace=yes` is safe and enabled
- CPU controller uses `cpu.weight` (relative weights) instead of `cpu.shares`
- Memory OOM kills are more precise (per-cgroup rather than system-wide)
- `CgroupAutomount=no` and `CgroupMountpoint` directives are removed — the v2 hierarchy
  has a single unified mount, not per-subsystem mounts

To verify on a running Gen 3 node:
```bash
mount | grep cgroup
# Should show: cgroup2 on /sys/fs/cgroup type cgroup2 (...)
# Should NOT show any "type cgroup " entries (v1)

# Confirm Slurm's cgroup v2 tree exists:
ls /sys/fs/cgroup/system.slice/slurmctld.service/ 2>/dev/null
```

### 2. iptables-services removed → iptables-nft

RHEL 10 removes the `iptables-services` package (which provided the `iptables.service`
systemd unit with its DROP-by-default ruleset). The package that provides the `/sbin/iptables`
binary is now `iptables-nft`, which implements iptables semantics via an nftables backend.

The Gen 3 Packer AMI (`ami/rocky10-slurm2405.pkr.hcl`) installs `iptables-nft` instead of
`iptables iptables-services`. This means:
- `iptables -t nat -A POSTROUTING ...` translates to nftables rules
- `iptables-save` and `iptables-restore` produce/consume iptables-format files, but the
  kernel stores rules in nftables internally
- The `burstlab-nat.service` (`ExecStart=/sbin/iptables-restore ...`) works unchanged

**For the head-node-init.sh.tpl:** the NAT setup code (`iptables -F`, `iptables -t nat ...`,
`iptables-save`, `burstlab-nat.service`) is identical to Gen 1/2 and works on Rocky 10 via
the nftables compat layer. No script changes needed.

The `systemctl stop iptables` / `systemctl disable iptables` calls in the init script now
fail silently (unit not found), which is expected and handled by `|| true`.

### 3. Crypto policy: RSA minimum key size raised to 3072 bits

RHEL 10's DEFAULT crypto policy raises the minimum RSA key size from 2048 bits (RHEL 9 DEFAULT)
to 3072 bits. Standard EC2 key pairs are 2048-bit RSA and are silently rejected by sshd when
this policy is in effect — the connection resets before the SSH version string exchange.

**BurstLab uses an Ed25519 key (`burstlab-key`), which is not affected by the RSA size
restriction.** Gen 3 stays on the `DEFAULT` crypto policy with no modification needed.

This is the cleanest solution: Ed25519 keys are smaller, faster, and not subject to the
RSA minimum-size policy. An earlier version of BurstLab used RSA-2048 and worked around this
by setting `update-crypto-policies --set LEGACY`, but switching to Ed25519 eliminates the
need to weaken the crypto policy.

If you bring your own RSA-2048 key instead of using `burstlab-key`, you have two options:
1. **Recommended:** create an Ed25519 key pair instead (`aws ec2 create-key-pair --key-type ed25519 ...`)
2. **Workaround:** set `update-crypto-policies --set LEGACY` on the instance to allow RSA-2048

Verify the crypto policy on a running Gen 3 instance:
```bash
update-crypto-policies --show
# Should print: DEFAULT
```

### 4. slurmrestd NOT built on Rocky 10

`http-parser-devel` (required for `--enable-slurmrestd`) was removed from EPEL 10. The
upstream `http-parser` library is archived/unmaintained and was dropped from EPEL 10.

The Gen 3 AMI build does **not** pass `--enable-slurmrestd` to Slurm's `configure`. The REST
API daemon is not available on Gen 3. This has no impact on the core BurstLab demo (job
submission, bursting, and accounting all work without slurmrestd).

If slurmrestd is required in the future, options include:
- Build `http-parser` from source before the Slurm build
- Wait for a RHEL 10-compatible replacement library to appear in EPEL 10

### 5. Python 3.12 default

Rocky 10 (RHEL 10) ships **Python 3.12** as `python3`. The AMI installs boto3 directly via
pip3 (`--break-system-packages` flag handles the PEP 668 externally-managed-environment
protection that RHEL 10 enforces strictly). No wrapper script is needed.

---

## What Changed: Slurm 23.11 → 24.05

### How burst nodes get their address — set by the plugin, not `cloud_reg_addrs`

> **Correction (from live Slurm 25.11 validation).** Earlier versions of this guide
> credited a `SlurmctldParameters=cloud_reg_addrs` option as "the key Gen 3
> improvement." That was wrong. `cloud_reg_addrs` is **not a documented `slurm.conf`
> option** (it does not appear in `slurm.conf.5` for 23.11, 24.05, 25.05, or 25.11),
> and Gen 3/5 clusters that carried it worked *despite* it, not because of it — Slurm
> 24.05 silently warned and ignored it. Slurm 25.11 rejects it outright as defunct.
> BurstLab no longer sets it (all generations). The real mechanism is below.

**How cloud node addresses actually work.** A burst node's `NodeName` (`aws-burst-0`)
has no `NodeAddr` in `slurm.conf` and doesn't resolve in DNS — only its EC2 hostname
(`ip-10-0-2-X…`) does. Slurm's documented model for this (see the `cloud_dns` option in
`slurm.conf.5`) is that the node's address is *unknown until the instance is created*,
and something must tell the controller the address after boot.

**That "something" is the AWS plugin's `resume.py`.** When a burst job is scheduled,
slurmctld runs `resume.py` (the `ResumeProgram`). It calls EC2 to launch the instance,
reads the assigned `PrivateIpAddress`, and pushes it into Slurm:

```
scontrol update nodename=aws-burst-0 nodeaddr=10.0.2.47 nodehostname=ip-10-0-2-47
```

So the controller learns the address from the plugin, before the node's slurmd even
registers — no `slurm.conf` parameter involved. This is why bursting works identically
across Gen 1–6 and every Slurm version: the plugin owns address assignment.

**What this looks like in `scontrol show node aws-burst-0` after a burst job:**
```
NodeName=aws-burst-0 Arch=x86_64 CoresPerSocket=4
   ...
   NodeAddr=10.0.2.47 NodeHostName=ip-10-0-2-47
   ...
```

The `NodeAddr` is populated at resume time by `resume.py` — it wasn't in `slurm.conf`.

**Demo talking point:**
*"Burst nodes don't need pre-configured IPs. When a job needs one, our resume script
launches the EC2 instance, grabs its IP, and tells the controller 'aws-burst-0 lives at
10.0.2.47.' The plugin owns that — no magic Slurm setting, which is why it's portable
across Slurm versions."*

### `TaskPlugin=task/cgroup` — unchanged from Gen 2

Same as Gen 2. `task/affinity` remains dropped.

### `slurmrestd` — API version update

The slurmrestd.service unit in Gen 3 uses the 24.05 OpenAPI spec:
```
ExecStart=... slurmrestd -a rest/local -s openapi/v0.0.40 -u slurm -g slurm
```

Gen 2 uses `openapi/v0.0.38`. The v0.0.40 spec adds new endpoints and deprecates some old
ones. The query pattern is the same:

```bash
# Start slurmrestd (not started by default)
systemctl start slurmrestd

# Query jobs
curl -s --unix-socket /var/spool/slurm/ctld/slurmrestd.socket \
  http://localhost/slurm/v0.0.40/jobs | python3 -m json.tool

# Query nodes (NodeAddr populated by resume.py at launch)
curl -s --unix-socket /var/spool/slurm/ctld/slurmrestd.socket \
  http://localhost/slurm/v0.0.40/nodes | python3 -m json.tool
```

### cgroup.conf: `CgroupPlugin=cgroup/v2` + `ConstrainSwapSpace=yes`

Full Gen 3 `cgroup.conf`:
```
CgroupPlugin=cgroup/v2
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainSwapSpace=yes   # safe on v2; first-class memory.swap.max knob
ConstrainDevices=no
```

`CgroupAutomount` and `CgroupMountpoint` are not set — they were v1-specific directives.
Slurm 24.05 ignores them with a warning if present on v2 systems.

---

## Generation Comparison Matrix

| Feature | Gen 1 | Gen 2 | Gen 3 |
|---------|-------|-------|-------|
| OS | Rocky 8 | Rocky 9 | Rocky 10 |
| Slurm | 22.05 | 23.11 | 24.05 |
| Python | 3.8 via module shim | 3.9 system | 3.12 system |
| Repo extra | powertools | crb | crb + epel |
| cgroup | v1 | v2 (EC2 AMI — no v1) | v2 (required) |
| iptables | iptables-services | iptables-services | iptables-nft |
| crypto policy | DEFAULT | DEFAULT | DEFAULT (Ed25519 key; RSA-2048 blocked) |
| `SlurmctldParameters` | *(none)* | idle_on_node_suspend | idle_on_node_suspend |
| slurmrestd | not built | built, not started | **not built** (http-parser-devel not in EPEL 10) |
| Cloud node IP | set by resume.py | set by resume.py | set by resume.py |
| sinfo cloud nodes | `idle~` | `idle~` | `idle~` |
| Plugin v2 | same | same | same |

---

## Building and Deploying Gen 3

Deploy exactly as the canonical [quickstart](quickstart.md) (build AMI → configure all
four `terraform.tfvars` values → apply → validate → demo), substituting the Gen 3
specifics:

| | Gen 3 value |
|---|---|
| Packer template | `ami/rocky10-slurm2405.pkr.hcl` |
| Terraform dir | `terraform/generations/gen3-slurm2405-rocky10` |
| AMI name filter | `burstlab-gen3-*` |
| SSH user | `rocky` |

Two Gen-3-specific notes:

```bash
# Before building: confirm a Rocky 10 source AMI exists in your region
aws ec2 describe-images --owners 792107900819 \
  --filters 'Name=name,Values=Rocky-10*' \
  --query 'Images[*].{Name:Name,ID:ImageId,Date:CreationDate}' --output table

# After a burst job runs: resume.py has set NodeAddr to the real EC2 IP
scontrol show node aws-burst-0 | grep NodeAddr
```

---

## Troubleshooting Gen 3-Specific Issues

**SSH connection reset immediately (`kex_exchange_identification: read: Connection reset`):**
- Rocky 10 DEFAULT crypto policy rejects RSA keys < 3072 bits. BurstLab's `burstlab-key` is
  Ed25519 and is not affected. If you see this error, you are likely using your own RSA-2048 key.
- Verify: `ssh rocky@<ip> 'update-crypto-policies --show'` should print `DEFAULT`.
- Fix: either switch to an Ed25519 key pair (recommended) or run
  `sudo update-crypto-policies --set LEGACY` on the instance to allow RSA-2048, then reconnect.
- **Known issue with SSH ControlMaster:** If your `~/.ssh/config` has `ControlMaster auto`
  with `ControlPersist`, the initial connection may succeed (reusing an existing master socket)
  but subsequent fresh connections fail after the persist timeout expires. This is what makes
  the problem intermittent. Switching to an Ed25519 key addresses the root cause.

**slurmd fails with `cgroup namespace not found` or `cgroup/v1 not supported`:**
- Rocky 10 has no v1. Confirm `cgroup.conf` has `CgroupPlugin=cgroup/v2`.
- Check `/sys/fs/cgroup/cgroup.controllers` exists (v2 root).

**`iptables: command not found` on head node:**
- `iptables-nft` provides `/sbin/iptables`. If missing: `dnf install -y iptables-nft`.
- Note: `systemctl enable iptables` will fail (no iptables.service) — this is expected.
  The `burstlab-nat.service` handles NAT persistence.

**`iptables-restore` fails on boot (burstlab-nat.service):**
- Rocky 10 `iptables-restore` from `iptables-nft` uses nftables internally; the save
  format may differ slightly from v1. If the service fails, regenerate the rules:
  ```bash
  iptables -F && iptables -F -t nat
  iptables -t nat -A POSTROUTING -s 10.0.1.0/24 -o eth0 -j MASQUERADE
  iptables -t nat -A POSTROUTING -s 10.0.2.0/24 -o eth0 -j MASQUERADE
  iptables -t nat -A POSTROUTING -s 10.0.3.0/24 -o eth0 -j MASQUERADE
  iptables-save > /etc/sysconfig/iptables-burstlab.rules
  systemctl restart burstlab-nat.service
  ```

**Burst nodes not registering (no NodeAddr / can't reach the node):**
- The address is set by `resume.py`, not a slurm.conf parameter. Check the plugin log
  for the `scontrol update … nodeaddr=` call: `grep -i nodeaddr /var/log/slurm/*.log`
  and `/var/log/slurm/change_state.log`.
- Confirm `resume.py` ran and succeeded (EC2 launch + address push):
  `scontrol show node aws-burst-0 | grep -E 'NodeAddr|State'`.
- Do NOT add `cloud_reg_addrs` to fix this — it is defunct on Slurm 25.11 and a no-op
  elsewhere (see "How burst nodes get their address" above).

**Python 3.12 PEP 668 blocking pip:**
- `sudo pip3 install boto3` may error: *"error: externally-managed-environment"*.
- Fix: `sudo pip3 install boto3 --break-system-packages`
- The Packer AMI already handles this, so this should only appear if boto3 is missing
  from a custom image.
