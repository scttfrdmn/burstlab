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

The Gen 3 Packer AMI sets the crypto policy to `LEGACY` via:
```
sudo update-crypto-policies --set LEGACY
```

The `LEGACY` policy matches RHEL 9's DEFAULT behavior and accepts 2048-bit RSA keys. This
allows existing `burstlab-key` EC2 key pairs to work without requiring users to create new
4096-bit or Ed25519 keys.

The policy is set at AMI build time and persists to disk (`/etc/crypto-policies/config`).
sshd reads it on startup and applies it to all connections — no runtime restart needed.

Verify on a running Gen 3 instance:
```bash
update-crypto-policies --show
# Should print: LEGACY
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

### `SlurmctldParameters=cloud_reg_addrs` — the key Gen 3 improvement

This is the most operationally significant change across the three BurstLab generations.

**The problem in Gen 1 and Gen 2:**

When a burst node boots, its slurmd attempts to register with slurmctld. slurmctld looks up
the node's `NodeAddr` (or `NodeHostname`) in `slurm.conf` to verify the registration. In
Gen 1/2, the NodeName entries for cloud nodes look like:

```
NodeName=cloud-burst-0 CPUs=8 RealMemory=31000 State=CLOUD
```

No `NodeAddr` is specified. Slurm resolves the address by doing a DNS lookup on `cloud-burst-0`
(the NodeName). On a cloud instance, this name doesn't resolve — only the EC2 hostname
(`ip-10-0-2-X.us-west-2.compute.internal`) resolves. slurmctld can refuse the registration
if the connection comes from an IP that doesn't match what it expects.

In practice on Gen 1/2, this usually works because AWS's cloud nodes connect from within the
same VPC and slurmctld accepts connections from any IP in the burst subnet. But it's fragile:
if security groups or network routing changes, registrations can silently fail.

**The Gen 3 solution: `cloud_reg_addrs`**

With `SlurmctldParameters=cloud_reg_addrs`, when a cloud node registers with slurmctld,
slurmctld **records the actual source IP of the TCP connection** as the node's address, and
stores it in the node table. Subsequent communications (job launch, health check) use that
recorded IP directly.

This means:
1. No DNS resolution required for cloud node registration
2. Works even if the node name doesn't resolve at all
3. Each burst node's IP is captured at boot time and forgotten at termination
4. Multiple deployments with different VPC CIDRs work without config changes

**What this looks like in `sinfo -o "%N %T %A"` after a burst job:**
```
NODELIST    STATE       REASON
cloud-burst-0   allocated   None
```

And in `scontrol show node cloud-burst-0`:
```
NodeName=cloud-burst-0 Arch=x86_64 CoresPerSocket=4
   ...
   NodeAddr=10.0.2.47 NodeHostName=cloud-burst-0
   ...
```

The `NodeAddr` is populated at registration time — it wasn't in `slurm.conf`.

**Demo talking point:**
*"In Gen 3, burst nodes don't need pre-configured IPs. When they boot, they just connect to
the controller and say 'I'm cloud-burst-0 and my IP is 10.0.2.47.' The controller records
that and uses it. This is how production cloud-bursting should work."*

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

# Query nodes (shows cloud_reg_addrs in action — NodeAddr populated)
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
| crypto policy | DEFAULT (RSA-2048 ok) | DEFAULT (RSA-2048 ok) | LEGACY (allows RSA-2048) |
| `SlurmctldParameters` | *(none)* | idle_on_node_suspend | idle_on_node_suspend, cloud_reg_addrs |
| slurmrestd | not built | built, not started | **not built** (http-parser-devel not in EPEL 10) |
| Cloud node IP | DNS/subnet match | DNS/subnet match | registered at connect |
| sinfo cloud nodes | `idle~` | `idle~` | `idle~` |
| Plugin v2 | same | same | same |

---

## Building and Deploying Gen 3

```bash
# 1. Verify Rocky 10 AMI is available in your region
AWS_PROFILE=aws aws ec2 describe-images --owners 792107900819 \
  --filters 'Name=name,Values=Rocky-10*' \
  --query 'Images[*].{Name:Name,ID:ImageId,Date:CreationDate}' \
  --output table

# 2. Build the Gen 3 AMI (~20 minutes)
AWS_PROFILE=aws packer build ami/rocky10-slurm2405.pkr.hcl

# 3. Find the AMI ID
AWS_PROFILE=aws aws ec2 describe-images --owners self \
  --filters 'Name=name,Values=burstlab-gen3-*' \
  --query 'sort_by(Images, &CreationDate)[-1].{ID:ImageId,Name:Name}' \
  --output table

# 4. Deploy
cd terraform/generations/gen3-slurm2405-rocky10
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set key_name and head_node_ami
terraform init
terraform apply

# 5. Connect and validate
ssh -i ~/.ssh/<key>.pem rocky@$(terraform output -raw head_node_public_ip)
bash /opt/slurm/etc/validate-cluster.sh

# 6. Demo
su - alice
bash /opt/slurm/etc/demo-burst.sh

# 7. Observe cloud_reg_addrs in action after a burst job runs:
scontrol show node aws-burst-0 | grep NodeAddr
```

---

## Troubleshooting Gen 3-Specific Issues

**SSH connection reset immediately (`kex_exchange_identification: read: Connection reset`):**
- Rocky 10 DEFAULT crypto policy rejects RSA keys < 3072 bits. The `burstlab-key` EC2 key
  pair is 2048-bit RSA. The Gen 3 AMI sets `update-crypto-policies --set LEGACY` to allow it.
- Verify: `ssh rocky@<ip> 'update-crypto-policies --show'` should print `LEGACY`.
- If a manually-built AMI is missing the policy: `sudo update-crypto-policies --set LEGACY`
  on the running instance, then reconnect.
- **Known issue with SSH ControlMaster:** If your `~/.ssh/config` has `ControlMaster auto`
  with `ControlPersist`, the initial connection may succeed (reusing an existing master socket)
  but subsequent fresh connections fail after the persist timeout expires. This is what makes
  the problem intermittent. The crypto policy fix addresses the root cause.

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

**Burst nodes not registering (`cloud_reg_addrs` not taking effect):**
- Confirm `SlurmctldParameters=idle_on_node_suspend,cloud_reg_addrs` is in `slurm.conf`
  (check the EFS copy: `grep SlurmctldParameters /opt/slurm/etc/slurm.conf`).
- After adding it, `scontrol reconfigure` is required — or restart slurmctld.

**Python 3.12 PEP 668 blocking pip:**
- `sudo pip3 install boto3` may error: *"error: externally-managed-environment"*.
- Fix: `sudo pip3 install boto3 --break-system-packages`
- The Packer AMI already handles this, so this should only appear if boto3 is missing
  from a custom image.
