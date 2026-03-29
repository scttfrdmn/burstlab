# BurstLab

BurstLab provisions disposable "mock on-prem" HPC clusters on AWS that replicate what universities actually run, with the AWS Plugin for Slurm v2 pre-configured for cloud bursting. It is a **learning platform** — every config, every design decision, and every AWS resource is documented so an SA or customer can understand exactly what was done and why.

This is not a canned demo. It is a transferable architecture. An SA can stand up a BurstLab cluster that matches a customer's Slurm version and OS, walk through the bursting configuration live, and hand over the IaC when the meeting ends.

---

## Architecture

```
VPC 10.0.0.0/16
├── management subnet  10.0.0.0/24  (us-west-2a) — head node, EIP, SSH entry
├── on-prem subnet     10.0.1.0/24  (us-west-2a) — static compute nodes (no public IPs)
├── cloud subnet A     10.0.2.0/24  (us-west-2a) — burst nodes
└── cloud subnet B     10.0.3.0/24  (us-west-2b) — burst nodes (multi-AZ)

Head node  (m7a.large):    slurmctld + slurmdbd + munge + NAT (iptables masquerade)
Compute nodes (m7a.large × 4):  slurmd, private only, internet via head node NAT
Burst nodes (m7a.xlarge):  launched by Plugin v2 via EC2 CreateFleet, same NAT path
EFS:  /home and /opt/slurm shared across all nodes
```

The head node is the cluster's NAT gateway — on-prem compute and burst nodes route all outbound traffic through it. This mirrors real university HPC environments where compute nodes live on isolated private networks with no direct internet access.

---

## What's in This Repo

```
burstlab/
├── README.md                        # This file
├── docs/
│   ├── architecture.md              # Network, EFS, NAT, IAM, and security design
│   ├── quickstart.md                # Deploy your first BurstLab in 15 minutes
│   ├── slurm-gen1-deep-dive.md      # Every slurm.conf directive explained
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
│   │   └── burst-config/            # Plugin v2 config files rendered from templates
│   └── generations/
│       └── gen1-slurm2205-rocky8/  # Complete Gen 1 root module
│
├── cdk/                             # AWS CDK (TypeScript) — parallel IaC
│   ├── lib/constructs/              # VPC, head node, storage, IAM constructs
│   └── lib/stacks/                  # Per-generation stack entry points
│
├── configs/
│   └── gen1-slurm2205-rocky8/      # Canonical Slurm config templates (source of truth)
│       ├── slurm.conf.tpl
│       ├── partitions.json.tpl
│       ├── plugin_config.json.tpl
│       ├── slurmdbd.conf.tpl
│       └── cgroup.conf
│
├── scripts/
│   ├── validate-cluster.sh          # Post-deploy validation: services, EFS, sinfo
│   └── userdata                     # Head node cloud-init bootstrap
│
└── ami/
    └── rocky8-slurm2205.pkr.hcl     # Packer template: Rocky Linux 8 + Slurm 22.05.11
```

---

## Slurm Generations

| Generation | OS | Slurm | Cloud Model | When to Use |
|---|---|---|---|---|
| **Gen 1** | CentOS 8 | 22.05.x | SuspendProgram / ResumeProgram scripts | Customers on CentOS 8 / RHEL 8, Slurm ≤ 23.02, Scyld ClusterWare, or any legacy HPC environment |
| **Gen 2** _(planned)_ | Rocky 8/9 | 23.11.x | Updated power save with dynamic node support | Customers who migrated off CentOS 8 but haven't reached 24.x |
| **Gen 3** _(planned)_ | Rocky 9 | 24.05.x | Stateless — no pre-enumerated burst nodes in slurm.conf | Greenfield deployments; cleanest bursting model |

### How to Choose

**Start with Gen 1** unless you know the customer is on Slurm 23.11+ or Rocky 9. Most university HPC environments that are actively struggling with cloud bursting today are running Slurm 22.x on CentOS/RHEL 8 or CentOS 7.

Gen 1 is also the right choice when:
- The customer is running Scyld ClusterWare, OpenHPC, or another Slurm distribution with non-standard paths
- You are troubleshooting a specific 22.05 issue (slurmdbd accounting, SelectType mismatches, missing serializer/json plugin)
- The customer's existing slurm.conf uses the traditional `SuspendProgram`/`ResumeProgram` model

---

## Getting Started

See [docs/quickstart.md](docs/quickstart.md) for the full step-by-step walkthrough.

Short version:

```bash
# 1. Build the AMI (~10-15 minutes)
cd ami/
packer build -var "aws_profile=aws" rocky8-slurm2205.pkr.hcl

# 2. Configure and deploy
cd terraform/generations/gen1-slurm2205-rocky8/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: key_name, head_node_ami
terraform init && terraform apply

# 3. Validate
ssh -i ~/.ssh/your-key.pem rocky@<head_node_public_ip>
sudo tail -f /var/log/burstlab-init.log  # wait for init
sinfo                                     # should show local + cloud partitions
```

---

## Why BurstLab Exists

University HPC environments share a common set of problems when attempting cloud bursting for the first time:

- **Config drift**: slurm.conf has diverged between the head node and login nodes
- **Missing plugins**: the `serializer/json` plugin is absent in some Slurm 22.05 builds, preventing slurmctld from starting
- **SelectType mismatches**: `select/linear` on one node, `select/cons_tres` on another
- **Broken accounting**: slurmdbd not running or not configured, which Plugin v2 requires
- **IAM gaps**: `iam:PassRole` missing, preventing EC2 Fleet from launching burst instances

BurstLab eliminates the "can we even get it working" phase. The Terraform and config templates represent known-good configurations for each Slurm generation. An SA can deploy a matching cluster in under 20 minutes and demonstrate working cloud bursting before a customer engagement even begins.

The immediate driver for this project was the TCU/Hannabyte engagement. TCU runs Slurm 22.05 on CentOS 8 under Scyld ClusterWare. Their slurmctld would not start due to the exact issues listed above. BurstLab Gen 1 documents and solves every one of them.

---

## Design Principles

1. **Correctness over cleverness.** Every config file should be something a university sysadmin can read and understand. No magic.
2. **Ephemeral by default.** `terraform destroy` cleans up everything. No orphaned resources.
3. **Match reality.** CentOS 8 with its broken EOL repos, not some idealized image. The point is to show it working in the messy conditions customers actually have.
4. **Configs are the product.** The IaC is scaffolding. The real value is the known-good `slurm.conf`, `partitions.json`, IAM policies, and security groups for each generation.
5. **Document the why.** Every directive, every AWS resource, every design choice has an explanation. The code is the documentation.

---

## Documentation

| Doc | Audience | Contents |
|---|---|---|
| [quickstart.md](docs/quickstart.md) | Everyone | Step-by-step deploy and validate |
| [architecture.md](docs/architecture.md) | SAs, technical customers | Network, EFS, NAT, IAM deep dive |
| [slurm-gen1-deep-dive.md](docs/slurm-gen1-deep-dive.md) | SAs, HPC admins | Every slurm.conf directive for Gen 1 |
| [plugin-v2-setup.md](docs/plugin-v2-setup.md) | SAs, HPC admins | Plugin v2 setup, configs, debugging |
| [sa-guide.md](docs/sa-guide.md) | SAs | How to run a customer demo |

---

## Contributing and Extending

BurstLab is intentionally structured for extension:

- **New Slurm version**: Copy `configs/gen1-slurm2205-rocky8/` to a new directory, update the config templates, add a Packer template, add a Terraform generation module.
- **New OS**: Swap the Packer source AMI and update the repo-fix steps. The rest of the provisioning logic is largely OS-agnostic.
- **New instance type**: Change `burst_instance_type` in `terraform.tfvars` and update the CPU/memory values in `partitions.json.tpl`.
- **Spot instances**: Set `"PurchasingOption": "spot"` in `partitions.json.tpl` and add a `SpotOptions` block with your interruption strategy.

The CDK implementation in `cdk/` is a parallel port of the Terraform code. Both produce identical clusters. Contributions to keep them in sync are welcome.
