# BurstLab Generations: The Why and the What

BurstLab ships three complete, independently-deployable cluster configurations. This
document explains why, what each one is for, and how to choose the right one.

---

## Why Three Generations?

HPC environments are not uniform. An SA engaging with five different research
computing teams in a single week might encounter:

- A team still on CentOS 8 (EOL December 2021) that migrated to Rocky 8 — running Slurm
  22.05, which they compiled from source three years ago and haven't touched since
- A team that upgraded to Rocky 9 last year and is on Slurm 23.11
- A brand-new cluster deployed on Rocky 10 with Slurm 24.05

A demo that only works on one configuration is limited. If you show a customer running
Slurm 22.05 a Gen 3 demo with `cloud_reg_addrs`, they cannot replicate it — the feature
does not exist in their version. The demo loses credibility.

BurstLab models the three most common live environments an SA encounters today.
Each generation is a complete, deployable cluster, not a variation of a single codebase.
The goal is to deploy a cluster that matches what a customer is actually running, walk
through the exact configuration they need, and hand over working IaC when the meeting ends.

---

## What Is Identical Across All Three

Before covering what differs, it is worth being explicit about what is the same:

- **Infrastructure**: the same six Terraform modules (VPC, IAM, EFS, head-node,
  compute-nodes, burst-config). The modules are not forked per generation — they are
  shared. Generation-specific differences are in config templates and Packer AMIs only.
- **AWS Plugin for Slurm v2**: all three generations run the same plugin version with
  the same `resume.py`, `suspend.py`, `change_state.py`, and `generate_conf.py` scripts.
  The plugin protocol has not changed between Slurm 22.05 and 24.05.
- **Scripts**: `validate-cluster.sh`, `demo-burst.sh`, and `check-quotas.sh` are
  generation-agnostic. The same 40-point validation and the same demo flow work on
  all three generations.
- **Deploy workflow**: `packer build` → `terraform apply` → SSH in → validate → demo.
  The steps are identical; only the AMI name and tfvars directory change.
- **Network architecture**: same four-subnet VPC, same EFS layout, same NAT setup,
  same security groups. An architecture diagram drawn for Gen 1 describes Gen 3 faithfully.
- **Alice**: the demo HPC user with UID/GID 2000 and home directory at `/u/home/alice`
  exists on all three generations.

---

## Generation 1 — Rocky Linux 8 + Slurm 22.05

**The target customer**: an HPC team that is struggling with cloud bursting
right now. Most of these teams are on RHEL/Rocky 8 with Slurm 22.05. The CentOS 8 EOL
in December 2021 drove a wave of migrations to Rocky 8. Many of these clusters are
running Slurm compiled from source three to four years ago and have not been upgraded.

**What makes Gen 1 distinctive:**

*Python 3.6 / boto3 shim.* Rocky 8's default Python is 3.6. The AWS Plugin for Slurm v2
requires boto3, which requires Python 3.7+. Gen 1 installs Python 3.8 via a DNF module
and creates a `/usr/local/bin/python3` wrapper that the plugin scripts use. This is the
exact workaround a customer's HPC admin would need to implement on their cluster.

*Pre-enumerated burst nodes in slurm.conf.* Gen 1 uses the standard Plugin v2 model:
`generate_conf.py` produces a `NodeName=aws-burst-[0-7]` stanza that is appended to
`slurm.conf` at first boot. Every potential burst node must be listed by name. Slurm
tracks them as CLOUD-state nodes that are powered off until needed.

*CentOS 8 EOL repo fix.* Gen 1 init scripts include logic to detect and fix broken CentOS
8 repos (`vault.centos.org`). This is irrelevant for Rocky 8 (which has active repos) but
demonstrates the exact fix a customer's sysadmin needed to apply when migrating.

*cgroup v1.* Rocky 8 EC2 AMIs boot with cgroup v1. The `cgroup.conf` uses
`CgroupPlugin=cgroup/v1` and `CgroupAutomount=yes`.

**Relevant customer profiles:**
- Running CentOS 8 or Rocky 8
- Slurm 22.x (any point release)
- Have never successfully burst to cloud, or bursting broke after a config change
- Common blockers: `serializer/json` missing, `SelectType` mismatch, broken slurmdbd

**Files:**
- AMI: `ami/rocky8-slurm2205.pkr.hcl`
- Config: `configs/gen1-slurm2205-rocky8/`
- Terraform: `terraform/generations/gen1-slurm2205-rocky8/`

---

## Generation 2 — Rocky Linux 9 + Slurm 23.11

**The target customer**: an HPC team that has already migrated to Rocky 9
(RHEL 9) or is planning to. These teams are typically on Slurm 23.x, which they either
upgraded to when moving OSes or adopted as the first version with official RHEL 9 support.

**What changes from Gen 1:**

*No Python shim.* Rocky 9 ships Python 3.9 as the default `python3`. boto3 installs
cleanly with `pip3 install boto3`. The plugin scripts use `#!/usr/bin/env python3`,
which resolves to `/usr/bin/python3` = Python 3.9 with boto3. No wrapper needed.

*CRB instead of powertools.* On Rocky 8, the extra-packages repo providing `-devel`
packages is called `powertools`. On Rocky 9, Red Hat renamed it to `crb` (CodeReady
Linux Builder). The Packer build must enable `crb` or the munge and Slurm dev package
dependencies will not resolve.

*cgroup v2 on EC2.* Rocky 9 EC2 AMIs (and RHEL 9 generally) boot with cgroup v2 as
the default. The `cgroup.conf` uses `CgroupPlugin=cgroup/v2`. The v1 hierarchy is
present but not used. This difference is transparent to normal job scheduling but
matters for cgroup-based memory and CPU enforcement.

*`idle_on_node_suspend` parameter.* Slurm 23.11 introduced
`SlurmctldParameters=idle_on_node_suspend`, which causes nodes to show as `idle` (not
`idle~`) briefly when transitioning back from POWER_DOWN to CLOUD state. This changes
the sinfo output during the suspend cycle and can confuse operators who are used to
Gen 1 behavior. Gen 2 includes this parameter; the deep-dive explains the state machine.

*Same bursting model as Gen 1.* The fundamental Plugin v2 bursting model — pre-enumerated
nodes, `generate_conf.py`, `CreateFleet` on resume — is unchanged in Slurm 23.11.

**Relevant customer profiles:**
- Running Rocky 9, AlmaLinux 9, or RHEL 9
- Slurm 23.x (typically 23.02 or 23.11)
- Recently migrated off CentOS 8/Rocky 8 and now setting up bursting for the first time
- Have a Slurm 22.x cluster they are upgrading and want to validate config changes

**Files:**
- AMI: `ami/rocky9-slurm2311.pkr.hcl`
- Config: `configs/gen2-slurm2311-rocky9/`
- Terraform: `terraform/generations/gen2-slurm2311-rocky9/`

---

## Generation 3 — Rocky Linux 10 + Slurm 24.05

**The target customer**: a team deploying a new cluster or upgrading to a modern stack.
This is the least common customer profile today but the fastest-growing — RHEL 10 was
released in May 2025 and major research computing centers are piloting it for new builds.

**What changes from Gen 2:**

*`cloud_reg_addrs` — the key architectural improvement.* This is the most important
change from a bursting perspective. In Gen 1 and Gen 2, burst nodes have a specific
IP address assigned in `slurm.conf` via `NodeAddr=`. When a node boots with a different
IP (because EC2 assigned a different address from the subnet), slurmctld rejects its
registration.

`SlurmctldParameters=cloud_reg_addrs`, added in Slurm 24.05, changes this: when a burst
node registers, slurmctld updates its `NodeAddr` with the actual IP the node is connecting
from. No pre-configured `NodeAddr` is needed. The `generate_conf.py` output does not
include `NodeAddr` lines for burst nodes. This eliminates an entire class of registration
failures that Gen 1/2 customers encounter.

*cgroup v2 only — no v1.* Rocky 10 (RHEL 10) compiles the kernel without
`CONFIG_CGROUP_V1=y`. The legacy cgroup v1 hierarchy does not exist. Only the unified
cgroup v2 hierarchy at `/sys/fs/cgroup` is available. The `cgroup.conf` must use
`CgroupPlugin=cgroup/v2`. Attempting to use `cgroup/v1` causes every slurmd to fail at
startup with `error: cgroup namespace not found`.

*iptables-nft instead of iptables-services.* RHEL 10 removes the `iptables-services`
package that provided the `iptables.service` systemd unit. The Gen 3 AMI installs
`iptables-nft` (iptables semantics over an nftables backend) instead. The BurstLab NAT
init scripts are unchanged because `iptables-nft` provides compatible command-line syntax.

*Python 3.12 default.* Rocky 10 ships Python 3.12 as the default. boto3 installs cleanly.
No shim is needed (same as Gen 2).

*RSA-2048 blocked by RHEL 10 crypto policy.* RHEL 10's `DEFAULT` crypto policy blocks
RSA-2048 keys. If the EC2 key pair used for SSH is RSA-2048, SSH connections to Gen 3
nodes will fail with `no matching host key type`. The Gen 3 Packer AMI sets
`LEGACY` crypto policy to allow RSA-2048. (EC2 key pairs generated in the console are
RSA-2048; ED25519 key pairs are not affected and do not require this workaround.)

**Relevant customer profiles:**
- Building a new cluster from scratch (greenfield deployment)
- Running RHEL 10 beta or Rocky 10 pilot
- Want the cleanest possible bursting configuration for a forward-looking architecture review
- Slurm 24.x (24.05 or newer)

**Files:**
- AMI: `ami/rocky10-slurm2405.pkr.hcl`
- Config: `configs/gen3-slurm2405-rocky10/`
- Terraform: `terraform/generations/gen3-slurm2405-rocky10/`

---

## Which Generation Should I Use?

| Customer Environment | Recommended Generation | Reason |
|---|---|---|
| CentOS 8 or Rocky 8, Slurm 22.x | **Gen 1** | Exact match — same OS, same Slurm version, same Python workaround |
| Rocky 8, Slurm 23.x (upgraded) | **Gen 1 or Gen 2** | OS matches Gen 1; Slurm version closer to Gen 2. Start with Gen 1 and note the Slurm version differences. |
| Rocky 9, AlmaLinux 9, RHEL 9, Slurm 23.x | **Gen 2** | Exact match |
| Rocky 9, Slurm 24.x (early adopter) | **Gen 2 or Gen 3** | OS matches Gen 2; Slurm version matches Gen 3. Cloud_reg_addrs may not be available in their 24.05 build — verify. |
| Rocky 10, RHEL 10, Slurm 24.05+ | **Gen 3** | Exact match |
| Not sure / first contact | **Gen 1** | Covers the largest installed base. You can always show Gen 3 diffs once you know their environment. |

When in doubt, deploy Gen 1. It is the most representative of what HPC teams are
actually struggling with today, and the Plugin v2 setup complexity is most visible on
Gen 1 (the Python shim, the cgroup v1 config, the pre-enumerated nodes). Showing a
customer a working Gen 1 cluster is more persuasive than showing a Gen 3 cluster that
requires Slurm 24.05 they do not have.

---

## The Generation Arc at a Glance

```
Gen 1 (Rocky 8, Slurm 22.05)
  ├── Python 3.6 → boto3 shim required
  ├── cgroup v1
  ├── Pre-enumerated nodes in slurm.conf (NodeAddr pre-set)
  └── CentOS 8 EOL repo handling

        ↓ OS upgrade: Rocky 8 → Rocky 9
        ↓ Slurm upgrade: 22.05 → 23.11

Gen 2 (Rocky 9, Slurm 23.11)
  ├── Python 3.9 → boto3 installs directly, no shim
  ├── cgroup v2 (default on RHEL 9 EC2)
  ├── idle_on_node_suspend parameter (new in 23.11)
  └── Pre-enumerated nodes in slurm.conf (same model as Gen 1)

        ↓ OS upgrade: Rocky 9 → Rocky 10
        ↓ Slurm upgrade: 23.11 → 24.05

Gen 3 (Rocky 10, Slurm 24.05)
  ├── Python 3.12 → boto3 installs directly
  ├── cgroup v2 only (v1 kernel support removed in RHEL 10)
  ├── cloud_reg_addrs → burst nodes self-register with actual EC2 IP (KEY IMPROVEMENT)
  ├── iptables-nft (iptables-services removed from RHEL 10)
  └── LEGACY crypto policy for RSA-2048 SSH key compatibility
```

---

## Deep Dives

Each generation has a companion document that explains every configuration decision at
the directive level:

- [slurm-gen1-deep-dive.md](slurm-gen1-deep-dive.md) — Every `slurm.conf` directive for
  Gen 1, including the Plugin v2 power-save directives and why each value was chosen.
  Read this first regardless of which generation you deploy.
- [slurm-gen2-deep-dive.md](slurm-gen2-deep-dive.md) — Gen 2 deltas from Gen 1:
  Rocky 9 OS differences, Slurm 23.11 new directives.
- [slurm-gen3-deep-dive.md](slurm-gen3-deep-dive.md) — Gen 3 deltas from Gen 2:
  `cloud_reg_addrs`, cgroup v2 only, Rocky 10 system-level changes.
