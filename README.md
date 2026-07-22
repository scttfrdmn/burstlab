# BurstLab

BurstLab provisions disposable "mock on-prem" HPC clusters on AWS that replicate what real HPC environments actually run, with the AWS Plugin for Slurm v2 pre-configured for cloud bursting. It is a **learning platform** — every config, every design decision, and every AWS resource is documented so an SA or customer can understand exactly what was done and why.

This is not a canned demo. It is a transferable architecture. An SA can stand up a BurstLab cluster that matches a customer's Slurm version and OS, walk through the bursting configuration live, and hand over the IaC when the meeting ends.

---

## Architecture

```
VPC 10.0.0.0/16
├── management subnet  10.0.0.0/24  (us-west-2a) — head node, EIP, SSH entry
├── on-prem subnet     10.0.1.0/24  (us-west-2a) — static compute nodes (no public IPs)
├── cloud subnet A     10.0.2.0/24  (us-west-2a) — burst nodes
└── cloud subnet B     10.0.3.0/24  (us-west-2b) — burst nodes (multi-AZ)

Head node  (m7a.2xlarge):     slurmctld + slurmdbd + munge + NAT (iptables masquerade)
Compute nodes (m7a.2xlarge × 4):  slurmd, private only, internet via head node NAT
Burst nodes (m7a.2xlarge):    launched by Plugin v2 via EC2 CreateFleet, same NAT path
EFS:  /u (user homes) and /opt/slurm (Slurm binaries + config) shared across all nodes
```

The head node is the cluster's NAT gateway — on-prem compute and burst nodes route all outbound traffic through it. This mirrors real on-prem HPC environments where compute nodes live on isolated private networks with no direct internet access.

---

## What's in This Repo

New here? Start with the **[documentation landing page](docs/README.md)** for a guided
path, or jump to [Getting Started](#getting-started) below. The full repository tree is
collapsed so it doesn't interrupt onboarding:

<details>
<summary>Full repository layout</summary>

```
burstlab/
├── README.md                        # This file
├── docs/
│   ├── prerequisites.md             # AWS quota requirements and pre-flight check
│   ├── quickstart.md                # Step-by-step: zero to running cluster (Gen 1)
│   ├── generations.md               # Why five generations exist; which to choose
│   ├── slurm-intro.md               # Slurm concepts and commands from zero
│   ├── architecture.md              # Network, EFS, NAT, IAM, and security design
│   ├── slurm-gen1-deep-dive.md      # Every slurm.conf directive explained (Gen 1)
│   ├── slurm-gen2-deep-dive.md      # Gen 2 config changes from Gen 1
│   ├── slurm-gen3-deep-dive.md      # Gen 3 config changes, cloud_reg_addrs
│   ├── plugin-v2-setup.md           # Plugin v2 setup: configs, debugging, IAM
│   ├── sa-guide.md                  # How to use BurstLab with customers
│   └── workloads/                   # Workloads overlay: data staging demos
│       ├── overview.md              # Scenario selection guide, storage tier matrix
│       ├── scenario1-compute.md     # GROMACS + Spack on burst nodes
│       ├── scenario2-roda.md        # RODA public datasets via s5cmd/rclone/Mountpoint
│       ├── scenario3-ephemeral-efs.md  # Job-scoped EFS: create → compute → destroy
│       └── scenario4-ephemeral-fsx.md  # Job-scoped FSx Lustre linked to S3
│
├── terraform/
│   ├── modules/
│   │   ├── vpc/                     # VPC, subnets, security groups, route tables
│   │   ├── head-node/               # Head node EC2, EIP, NAT routing
│   │   ├── compute-nodes/           # Static on-prem compute EC2 instances
│   │   ├── shared-storage/          # EFS filesystem and mount targets
│   │   ├── iam/                     # Head node and burst node IAM roles
│   │   └── burst-config/            # Plugin v2 config files and launch template
│   ├── generations/
│   │   ├── gen1-slurm2205-rocky8/      # Gen 1: Rocky 8 + Slurm 22.05
│   │   ├── gen2-slurm2311-rocky9/      # Gen 2: Rocky 9 + Slurm 23.11
│   │   ├── gen3-slurm2405-rocky10/     # Gen 3: Rocky 10 + Slurm 24.05
│   │   ├── gen4-slurm2311-ubuntu2204/  # Gen 4: Ubuntu 22.04 + Slurm 23.11
│   │   └── gen5-slurm2405-ubuntu2404/  # Gen 5: Ubuntu 24.04 + Slurm 24.05
│   └── workloads/                   # Overlay: attaches to existing generation clusters
│       ├── base/                    # S3 bucket, transfer tools, script deploy
│       ├── scenario1-compute/       # Spack + GROMACS install
│       ├── scenario2-roda/          # S3 read policy + results bucket
│       ├── scenario3-ephemeral-efs/ # EFS lifecycle IAM policies
│       ├── scenario3-wrapper/       # efs-sbatch drop-in wrapper deploy
│       ├── scenario3-prolog-epilog/ # EFS prolog/epilog + slurm.conf patch
│       ├── scenario4-ephemeral-fsx/ # FSx + S3 policies, service-linked role
│       ├── scenario4-wrapper/       # fsx-sbatch drop-in wrapper deploy
│       ├── scenario4-prolog-epilog/ # FSx prolog/epilog + slurm.conf patch
│       └── scenario4-burst-buffer/  # Lua burst buffer plugin deploy
│
├── configs/
│   ├── gen1-slurm2205-rocky8/       # Gen 1 config templates (Rocky 8)
│   ├── gen2-slurm2311-rocky9/       # Gen 2 config templates (Rocky 9)
│   ├── gen3-slurm2405-rocky10/      # Gen 3 config templates (Rocky 10)
│   ├── gen4-slurm2311-ubuntu2204/   # Gen 4 config templates (Ubuntu 22.04)
│   └── gen5-slurm2405-ubuntu2404/   # Gen 5 config templates (Ubuntu 24.04)
│
├── scripts/
│   ├── check-quotas.sh              # Pre-flight AWS quota check
│   ├── validate-cluster.sh          # Post-deploy health check (40 checks)
│   ├── demo-burst.sh                # Interactive burst demo (run as alice via SSH)
│   ├── teardown.sh                  # Graceful cluster shutdown + terraform destroy
│   ├── userdata/                    # Cloud-init scripts for each node type
│   │   ├── head-node-init.sh.tpl
│   │   ├── compute-node-init.sh.tpl
│   │   └── burst-node-init.sh.tpl
│   └── workloads/                   # Workloads overlay scripts (deployed to EFS)
│       ├── install-transfer-tools.sh  # rclone, s5cmd, Mountpoint
│       ├── install-spack.sh           # Spack + Lmod via AWS binary cache
│       ├── install-gromacs.sh         # GROMACS via Spack
│       ├── lib/
│       │   ├── efs-lifecycle.sh       # EFS create/wait/destroy helpers
│       │   └── fsx-lifecycle.sh       # FSx Lustre create/wait/flush/destroy helpers
│       └── jobs/
│           ├── scenario1/             # GROMACS job scripts
│           ├── scenario2/             # RODA data access job scripts
│           ├── scenario3/             # Ephemeral EFS: chain, wrapper, prolog/epilog
│           └── scenario4/             # Ephemeral FSx: chain, wrapper, prolog/epilog, BB
│
├── ami/
│   ├── rocky8-slurm2205.pkr.hcl     # Packer: Rocky 8 + Slurm 22.05 (Gen 1)
│   ├── rocky9-slurm2311.pkr.hcl     # Packer: Rocky 9 + Slurm 23.11 (Gen 2)
│   ├── rocky10-slurm2405.pkr.hcl    # Packer: Rocky 10 + Slurm 24.05 (Gen 3)
│   ├── ubuntu2204-slurm2311.pkr.hcl # Packer: Ubuntu 22.04 + Slurm 23.11 (Gen 4)
│   └── ubuntu2404-slurm2405.pkr.hcl # Packer: Ubuntu 24.04 + Slurm 24.05 (Gen 5)
│
└── cdk/                             # Experimental CDK (Go), Gen 1 only — see cdk/README.md
```

</details>

---

## Getting Started

> ⚠️ **Lab / reference environment — not production.** BurstLab creates **billable AWS
> resources** and is meant to be stood up, demonstrated, and torn down. The idle base
> cluster costs roughly **$1.80/hour (~$43/day)** before any burst nodes; each active
> burst node adds more. The default lab configuration **permits broad SSH access
> (0.0.0.0/0)** for convenience — restrict the security group for any non-throwaway use.
> Review your service quotas, and run `terraform destroy` when finished. See
> [docs/prerequisites.md](docs/prerequisites.md) (cost, quota, security) and the
> [support matrix](docs/support-matrix.md) (what works where).

**Before deploying**, check your AWS quota headroom — a low vCPU quota is the most common
reason a deploy fails partway through. First set your shell up from a clean checkout:

```bash
git clone https://github.com/scttfrdmn/burstlab.git
cd burstlab
export BURSTLAB_ROOT="$PWD"
export AWS_PROFILE="your-profile"      # e.g. aws
export AWS_REGION="us-west-2"
export SSH_KEY="$HOME/.ssh/burstlab-key.pem"

bash scripts/check-quotas.sh --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

See [docs/prerequisites.md](docs/prerequisites.md) for full requirements and how to request
quota increases. See [docs/generations.md](docs/generations.md) to choose the right generation
for your customer, and [docs/support-matrix.md](docs/support-matrix.md) for the authoritative
capability status of each generation.

See [docs/quickstart.md](docs/quickstart.md) for the full step-by-step walkthrough with time estimates.

Short version (Gen 1 — the recommended default). This is an at-a-glance outline; the
[quickstart](docs/quickstart.md) is the authoritative version with every step, expected
output, and caveats. Assumes you have exported `BURSTLAB_ROOT`, `AWS_PROFILE`,
`AWS_REGION`, and `SSH_KEY` as shown above.

```bash
# 1. Build the AMI (~15-20 minutes)
packer init "$BURSTLAB_ROOT/ami"
packer build -var "aws_profile=$AWS_PROFILE" -var "aws_region=$AWS_REGION" "$BURSTLAB_ROOT/ami/rocky8-slurm2205.pkr.hcl"

# 2. Configure and deploy (~5 minutes)
cd "$BURSTLAB_ROOT/terraform/generations/gen1-slurm2205-rocky8/"
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set aws_profile, aws_region, key_name, head_node_ami.
# aws_profile/aws_region are Terraform variables — exporting the shell vars does NOT
# override them (see quickstart Step 2).
terraform init && terraform apply

# 3. Wait for cluster init (~10-15 minutes), then connect
ssh -i "$SSH_KEY" rocky@<head_node_public_ip>
sudo tail -f /var/log/burstlab-init.log   # watch init progress
sinfo                                      # should show local + cloud partitions

# 4. When done — always tear down to stop billing
terraform destroy
```

---

## Slurm Generations

BurstLab provides five complete generations spanning two OS families (RHEL/Rocky and Ubuntu).
Each is an independently deployable cluster matching a specific customer environment.

### RHEL/Rocky Track

| Generation | OS | Slurm | Key Features | When to Use |
|---|---|---|---|---|
| **Gen 1** | Rocky 8 | 22.05.x | Python 3.6 boto3 shim; cgroup v1; FSx ✅ | RHEL/Rocky 8, Slurm 22.x — largest installed base |
| **Gen 2** | Rocky 9 | 23.11.x | Python 3.9 native; cgroup v2; FSx ✅ | RHEL/Rocky 9, Slurm 23.x |
| **Gen 3** | Rocky 10 | 24.05.x | `cloud_reg_addrs`; cgroup v2 only; Ed25519; [FSx requires burstlab-lustre](https://github.com/scttfrdmn/burstlab-lustre) | RHEL/Rocky 10, Slurm 24.x; greenfield |

### Ubuntu Track

| Generation | OS | Slurm | Key Features | When to Use |
|---|---|---|---|---|
| **Gen 4** | Ubuntu 22.04 | 23.11.x | apt/AppArmor; Python 3.10; cgroup v2; [FSx requires burstlab-lustre](https://github.com/scttfrdmn/burstlab-lustre) | Ubuntu 22.04, Slurm 23.x; academic/cloud-native/NVIDIA |
| **Gen 5** | Ubuntu 24.04 | 24.05.x | apt/AppArmor; Python 3.12; `cloud_reg_addrs`; [FSx requires burstlab-lustre](https://github.com/scttfrdmn/burstlab-lustre) | Ubuntu 24.04, Slurm 24.x; latest LTS |

**Start with Gen 1 for RHEL/Rocky customers** or **Gen 4 for Ubuntu customers** unless you know
the specific OS and Slurm version. Most HPC teams struggling with cloud bursting today are on
Rocky 8 with Slurm 22.05.

**FSx Lustre on Gen 3-5:** AWS doesn't provide Lustre packages for Rocky 10 or Ubuntu LTS versions. Install Lustre clients from [burstlab-lustre](https://github.com/scttfrdmn/burstlab-lustre) to enable FSx support on Gen 3, Gen 4, and Gen 5 clusters. EFS workloads work on all generations without additional setup.

See [docs/generations.md](docs/generations.md) for detailed comparison, decision tables, and
architectural differences between generations. See [docs/quickstart-ubuntu.md](docs/quickstart-ubuntu.md) for
Ubuntu-specific quick start.

---

## Workloads Track

The workloads overlay demonstrates how HPC applications consume and produce data
in a cloud bursting environment. It builds on top of any deployed generation cluster
without modifying the core Terraform state or base infrastructure. (Some approaches do
add to the running cluster — e.g. the wrapper installs to shared EFS and prolog/epilog
patches `slurm.conf` — as additive overlays, not base-generation changes.)

| Scenario | Story | Storage |
|----------|-------|---------|
| **1 — Compute** | GROMACS + Spack, no data staging | EFS only |
| **2 — RODA** | Read public AWS datasets (NOAA GOES-16) | S3 read-only |
| **3 — Ephemeral EFS** | Job-scoped NFS scratch, three lifecycle approaches (0/A/B) | EFS ephemeral |
| **4 — Ephemeral FSx** | Job-scoped Lustre scratch linked to S3, four lifecycle approaches (0/A/B/C) | FSx + S3 |

Scenarios 3 and 4 trigger storage lifecycle through a set of approaches, from explicit to
transparent — Scenario 3 offers 0/A/B, and Scenario 4 adds the FSx-only Burst Buffer (C):

| Approach | How to submit | User sees |
|----------|--------------|-----------|
| **0 — Chain** | `bash submit-chain.sh` | Three job IDs with dependencies |
| **A — Wrapper** | `fsx-sbatch myjob.sh` | One job ID |
| **B — Prolog/Epilog** | `sbatch --comment=fsx:1200 myjob.sh` | One job ID; storage created silently |
| **C — Burst Buffer** | `sbatch myjob.sh` (with `#BB` directive) | BF → R → CG state transitions |

> **Approach C (Burst Buffer)** needs `burst_buffer_lua.so`, which requires the AMI to
> be built with Lua headers present. The Packer recipes now include this dependency
> (issue #6), but **already-built AMIs must be rebuilt** to enable it — until then use
> Approach B. See the [support matrix](docs/support-matrix.md) for current per-generation
> status of every approach.

```bash
# Deploy the base overlay (once per cluster). Configure its tfvars first — the example
# defaults to Gen 1 / profile "aws" / us-west-2, so if you deployed a different
# generation, profile, region, or cluster_name you must set those too.
cd "$BURSTLAB_ROOT/terraform/workloads/base"
cp terraform.tfvars.example terraform.tfvars
# Edit: gen_state_path, key_path (always) + aws_profile, aws_region, cluster_name
#       (if you deviated from the Gen 1 / aws / us-west-2 defaults)
terraform init && terraform apply

# Deploy a scenario
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx" init
terraform -chdir="$BURSTLAB_ROOT/terraform/workloads/scenario4-ephemeral-fsx" apply

# Run it — on the head node as alice
ssh -i ~/.ssh/burstlab-key.pem alice@<head_node_ip>
bash /opt/slurm/etc/workloads/jobs/scenario4/submit-chain.sh
```

See [docs/workloads/overview.md](docs/workloads/overview.md) for scenario selection,
storage tier decision matrix, and granularity modes (per-job, per-array, per-campaign).
See [docs/workloads/transparent-lifecycle.md](docs/workloads/transparent-lifecycle.md)
for a full comparison of the three transparent lifecycle approaches.

---

## Alternative IaC: CDK (Go, experimental)

The primary, fully-supported implementation is **Terraform** (all five
generations + the workloads overlay). For teams that prefer a CDK /
CloudFormation workflow, `cdk/` provides an **experimental AWS CDK (Go)**
implementation that currently covers **Gen 1 only** and does not include the
workloads overlay. It reuses the same config and UserData templates as
Terraform. See [cdk/README.md](cdk/README.md) for scope, build, and deploy
instructions.

---

## Why BurstLab Exists

On-prem HPC environments share a common set of problems when attempting cloud bursting for the first time:

- **Config drift**: slurm.conf has diverged between the head node and login nodes
- **Missing plugins**: the `serializer/json` plugin is absent in some Slurm 22.05 builds, preventing slurmctld from starting
- **SelectType mismatches**: `select/linear` on one node, `select/cons_tres` on another
- **Broken accounting**: slurmdbd not running or not configured, which Plugin v2 requires
- **IAM gaps**: `iam:PassRole` missing, preventing EC2 Fleet from launching burst instances

BurstLab eliminates the "can we even get it working" phase. The Terraform and config templates represent known-good configurations for each Slurm generation. Stand-up takes roughly 30–40 minutes from a clean checkout, or under 30 minutes when reusing a prebuilt AMI — so an SA can have a matching cluster demonstrating working cloud bursting before a customer engagement even begins.

---

## Design Principles

1. **Correctness over cleverness.** Every config file should be something an HPC sysadmin can read and understand. No magic.
2. **Ephemeral by default.** `terraform destroy` cleans up all Terraform-managed ephemeral infrastructure. A few things are intentionally *not* Terraform-managed and need explicit cleanup: Packer-built AMIs and their snapshots (see quickstart Step 8), durable results buckets created by Scenario 4, and any FSx filesystem left behind when a destroy job fails.
3. **Match reality.** Rocky Linux 8 with the same repo and package constraints customers face — not some idealized image.
4. **Configs are the product.** The IaC is scaffolding. The real value is the known-good `slurm.conf`, `partitions.json`, IAM policies, and security groups for each generation.
5. **Document the why.** Every directive, every AWS resource, every design choice has an explanation. The code is the documentation.

---

## Documentation

| Doc | Audience | Contents |
|---|---|---|
| [support-matrix.md](docs/support-matrix.md) | Everyone | **Single source of truth** — per-generation node counts, EFS/FSx, lifecycle, status |
| [prerequisites.md](docs/prerequisites.md) | Everyone | AWS quota requirements and pre-flight check |
| [quickstart.md](docs/quickstart.md) | Everyone | Step-by-step deploy with time estimates (Gen 1) |
| [generations.md](docs/generations.md) | Everyone | Why five generations exist; which to choose |
| [quickstart-ubuntu.md](docs/quickstart-ubuntu.md) | Ubuntu users | Ubuntu-specific deltas from the canonical quickstart (Gen 4 & 5) |
| [roadmap.md](docs/roadmap.md) | Everyone | Planned work and project direction |
| [slurm-intro.md](docs/slurm-intro.md) | Everyone | Slurm concepts and commands from zero |
| [architecture.md](docs/architecture.md) | SAs, technical customers | Network, EFS, NAT, IAM deep dive |
| [slurm-gen1-deep-dive.md](docs/slurm-gen1-deep-dive.md) | SAs, HPC admins | Every slurm.conf directive for Gen 1 |
| [slurm-gen2-deep-dive.md](docs/slurm-gen2-deep-dive.md) | SAs, HPC admins | Gen 2 config changes from Gen 1 |
| [slurm-gen3-deep-dive.md](docs/slurm-gen3-deep-dive.md) | SAs, HPC admins | Gen 3 config changes, `cloud_reg_addrs` |
| [plugin-v2-setup.md](docs/plugin-v2-setup.md) | SAs, HPC admins | Plugin v2 setup, configs, debugging |
| [sa-guide.md](docs/sa-guide.md) | SAs | How to run a customer demo |
| [workloads/overview.md](docs/workloads/overview.md) | SAs | Workloads overlay: scenario guide, storage tiers |
| [workloads/scenario1-compute.md](docs/workloads/scenario1-compute.md) | SAs | GROMACS + Spack demo |
| [workloads/scenario2-roda.md](docs/workloads/scenario2-roda.md) | SAs | RODA public datasets, s5cmd/rclone/Mountpoint |
| [workloads/user-guide.md](docs/workloads/user-guide.md) | Cluster users | How to use fsx-sbatch, efs-sbatch, fsx-list/restore/purge |
| [workloads/scenario3-ephemeral-efs.md](docs/workloads/scenario3-ephemeral-efs.md) | SAs | Ephemeral EFS: chain, wrapper, prolog/epilog |
| [workloads/scenario4-ephemeral-fsx.md](docs/workloads/scenario4-ephemeral-fsx.md) | SAs | Ephemeral FSx Lustre + S3: chain, wrapper, prolog/epilog, burst buffer |
| [workloads/transparent-lifecycle.md](docs/workloads/transparent-lifecycle.md) | SAs | Approach comparison: chain vs wrapper vs prolog/epilog vs burst buffer |
| [blog/multi-instance-partitions.md](docs/blog/multi-instance-partitions.md) | SAs, HPC admins | Blog: right-sizing Slurm nodes — one partition backed by a c/m/r instance catalog, cheapest-fit via Weight; ParallelCluster + PCS examples in [blog/examples/](docs/blog/examples/) |

---

## Contributing and Extending

BurstLab is intentionally structured for extension:

- **New Slurm version**: Copy `configs/gen1-slurm2205-rocky8/` to a new directory, update the config templates, add a Packer template, add a Terraform generation module.
- **New OS**: Swap the Packer source AMI and update the repo-fix steps in the init scripts.
- **New instance type**: Change instance types in `terraform.tfvars` and update the CPU/memory values in `partitions.json.tpl` and `slurm.conf.tpl` to match.
- **Spot instances**: Set `"PurchasingOption": "spot"` in `partitions.json.tpl` and add a `SpotOptions` block with your interruption strategy.
