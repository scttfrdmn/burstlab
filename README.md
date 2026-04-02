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

```
burstlab/
├── README.md                        # This file
├── docs/
│   ├── prerequisites.md             # AWS quota requirements and pre-flight check
│   ├── quickstart.md                # Step-by-step: zero to running cluster (Gen 1)
│   ├── generations.md               # Why three generations exist; which to choose
│   ├── slurm-intro.md               # Slurm concepts and commands from zero
│   ├── architecture.md              # Network, EFS, NAT, IAM, and security design
│   ├── slurm-gen1-deep-dive.md      # Every slurm.conf directive explained (Gen 1)
│   ├── slurm-gen2-deep-dive.md      # Gen 2 config changes from Gen 1
│   ├── slurm-gen3-deep-dive.md      # Gen 3 config changes, cloud_reg_addrs
│   ├── plugin-v2-setup.md           # Plugin v2 setup: configs, debugging, IAM
│   └── sa-guide.md                  # How to use BurstLab with customers
│
├── terraform/
│   ├── modules/
│   │   ├── vpc/                     # VPC, subnets, security groups, route tables
│   │   ├── head-node/               # Head node EC2, EIP, NAT routing
│   │   ├── compute-nodes/           # Static on-prem compute EC2 instances
│   │   ├── shared-storage/          # EFS filesystem and mount targets
│   │   ├── iam/                     # Head node and burst node IAM roles
│   │   └── burst-config/            # Plugin v2 config files and launch template
│   └── generations/
│       ├── gen1-slurm2205-rocky8/   # Complete Gen 1 root module (Rocky 8 + Slurm 22.05)
│       ├── gen2-slurm2311-rocky9/   # Complete Gen 2 root module (Rocky 9 + Slurm 23.11)
│       └── gen3-slurm2405-rocky10/  # Complete Gen 3 root module (Rocky 10 + Slurm 24.05)
│
├── configs/
│   ├── gen1-slurm2205-rocky8/       # Gen 1 Slurm config templates
│   │   ├── slurm.conf.tpl
│   │   ├── partitions.json.tpl
│   │   ├── plugin_config.json.tpl
│   │   ├── slurmdbd.conf.tpl
│   │   └── cgroup.conf
│   ├── gen2-slurm2311-rocky9/       # Gen 2 Slurm config templates
│   └── gen3-slurm2405-rocky10/      # Gen 3 Slurm config templates
│
├── scripts/
│   ├── check-quotas.sh              # Pre-flight AWS quota check
│   ├── validate-cluster.sh          # Post-deploy health check (40 checks)
│   ├── demo-burst.sh                # Interactive burst demo (run as alice via SSH)
│   ├── teardown.sh                  # Graceful cluster shutdown + terraform destroy
│   └── userdata/                    # Cloud-init scripts for each node type
│       ├── head-node-init.sh.tpl
│       ├── compute-node-init.sh.tpl
│       └── burst-node-init.sh.tpl
│
└── ami/
    ├── rocky8-slurm2205.pkr.hcl     # Packer: Rocky Linux 8 + Slurm 22.05 (Gen 1)
    ├── rocky9-slurm2311.pkr.hcl     # Packer: Rocky Linux 9 + Slurm 23.11 (Gen 2)
    └── rocky10-slurm2405.pkr.hcl    # Packer: Rocky Linux 10 + Slurm 24.05 (Gen 3)
```

---

## Getting Started

**Before deploying**, check your AWS quota headroom — a low vCPU quota is the most common
reason a deploy fails partway through:

```bash
bash scripts/check-quotas.sh --profile aws --region us-west-2
```

See [docs/prerequisites.md](docs/prerequisites.md) for full requirements and how to request
quota increases. See [docs/generations.md](docs/generations.md) to choose the right generation
for your customer.

See [docs/quickstart.md](docs/quickstart.md) for the full step-by-step walkthrough with time estimates.

Short version (Gen 1 — the recommended default):

```bash
# 1. Build the AMI (~15-20 minutes)
cd ami/
packer build -var "aws_profile=aws" rocky8-slurm2205.pkr.hcl

# 2. Configure and deploy (~5 minutes)
cd terraform/generations/gen1-slurm2205-rocky8/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set key_name and head_node_ami
terraform init && terraform apply

# 3. Wait for cluster init (~10-15 minutes), then connect
ssh -i ~/.ssh/your-key.pem rocky@<head_node_public_ip>
sudo tail -f /var/log/burstlab-init.log   # watch init progress
sinfo                                      # should show local + cloud partitions
```

---

## Slurm Generations

All three generations are fully built and tested. Each is an independently deployable
cluster matching a specific customer environment.

| Generation | OS | Slurm | Key Difference | When to Use |
|---|---|---|---|---|
| **Gen 1** | Rocky Linux 8 | 22.05.x | Python 3.6 boto3 shim; cgroup v1; pre-enumerated burst nodes | Customers on RHEL/Rocky 8, Slurm 22.x — the largest installed base |
| **Gen 2** | Rocky Linux 9 | 23.11.x | Python 3.9 native; cgroup v2; `idle_on_node_suspend` | Customers on RHEL/Rocky 9, Slurm 23.x |
| **Gen 3** | Rocky Linux 10 | 24.05.x | `cloud_reg_addrs` — burst nodes self-register with actual EC2 IP | Customers on RHEL/Rocky 10, Slurm 24.x; greenfield deployments |

**Start with Gen 1** unless you know the customer's OS and Slurm version. Most HPC teams
actively struggling with cloud bursting today are on Rocky 8 with Slurm 22.05.

See [docs/generations.md](docs/generations.md) for the full narrative: why three generations
exist, what each one solves, and a decision table for matching a customer to the right generation.

---

## Why BurstLab Exists

On-prem HPC environments share a common set of problems when attempting cloud bursting for the first time:

- **Config drift**: slurm.conf has diverged between the head node and login nodes
- **Missing plugins**: the `serializer/json` plugin is absent in some Slurm 22.05 builds, preventing slurmctld from starting
- **SelectType mismatches**: `select/linear` on one node, `select/cons_tres` on another
- **Broken accounting**: slurmdbd not running or not configured, which Plugin v2 requires
- **IAM gaps**: `iam:PassRole` missing, preventing EC2 Fleet from launching burst instances

BurstLab eliminates the "can we even get it working" phase. The Terraform and config templates represent known-good configurations for each Slurm generation. An SA can deploy a matching cluster in under 30 minutes and demonstrate working cloud bursting before a customer engagement even begins.

---

## Design Principles

1. **Correctness over cleverness.** Every config file should be something an HPC sysadmin can read and understand. No magic.
2. **Ephemeral by default.** `terraform destroy` cleans up everything. No orphaned resources.
3. **Match reality.** Rocky Linux 8 with the same repo and package constraints customers face — not some idealized image.
4. **Configs are the product.** The IaC is scaffolding. The real value is the known-good `slurm.conf`, `partitions.json`, IAM policies, and security groups for each generation.
5. **Document the why.** Every directive, every AWS resource, every design choice has an explanation. The code is the documentation.

---

## Documentation

| Doc | Audience | Contents |
|---|---|---|
| [prerequisites.md](docs/prerequisites.md) | Everyone | AWS quota requirements and pre-flight check |
| [quickstart.md](docs/quickstart.md) | Everyone | Step-by-step deploy with time estimates (Gen 1) |
| [generations.md](docs/generations.md) | Everyone | Why three generations exist; which to choose |
| [slurm-intro.md](docs/slurm-intro.md) | Everyone | Slurm concepts and commands from zero |
| [architecture.md](docs/architecture.md) | SAs, technical customers | Network, EFS, NAT, IAM deep dive |
| [slurm-gen1-deep-dive.md](docs/slurm-gen1-deep-dive.md) | SAs, HPC admins | Every slurm.conf directive for Gen 1 |
| [slurm-gen2-deep-dive.md](docs/slurm-gen2-deep-dive.md) | SAs, HPC admins | Gen 2 config changes from Gen 1 |
| [slurm-gen3-deep-dive.md](docs/slurm-gen3-deep-dive.md) | SAs, HPC admins | Gen 3 config changes, `cloud_reg_addrs` |
| [plugin-v2-setup.md](docs/plugin-v2-setup.md) | SAs, HPC admins | Plugin v2 setup, configs, debugging |
| [sa-guide.md](docs/sa-guide.md) | SAs | How to run a customer demo |

---

## Contributing and Extending

BurstLab is intentionally structured for extension:

- **New Slurm version**: Copy `configs/gen1-slurm2205-rocky8/` to a new directory, update the config templates, add a Packer template, add a Terraform generation module.
- **New OS**: Swap the Packer source AMI and update the repo-fix steps in the init scripts.
- **New instance type**: Change instance types in `terraform.tfvars` and update the CPU/memory values in `partitions.json.tpl` and `slurm.conf.tpl` to match.
- **Spot instances**: Set `"PurchasingOption": "spot"` in `partitions.json.tpl` and add a `SpotOptions` block with your interruption strategy.
