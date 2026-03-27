# BurstLab

## Project Specification

### Purpose

BurstLab provisions disposable "mock on-prem" HPC clusters on AWS that replicate what universities actually run, with the AWS Plugin for Slurm v2 pre-configured and ready to burst. The goal is to give AWS Solutions Architects and customers a working, SSH-able reference environment they can learn from and copy.

This is **not** a demo or a canned walkthrough — it's a transferable architecture. An SA should be able to stand up a BurstLab cluster that matches a customer's Slurm version and OS, walk through the bursting config live, and hand over the IaC.

### Context

This project supports the AWS BD work around academic HPC cloud adoption (CloudRamp). The immediate driver is the TCU/Hannabyte engagement, where we discovered that:

- TCU runs Scyld ClusterWare with Slurm under `/opt/scyld/slurm/`
- Their `slurm.conf` had diverged between head node (hpccw01) and login node (hpclogin)
- The `serializer/json` plugin was missing, preventing slurmctld from starting
- Cloud bursting directives were commented out on the controller but active on login node
- `SelectType` was mismatched across nodes

These are **typical** problems at universities attempting bursting. BurstLab eliminates the "can we even get it working" phase by providing known-good configurations for each Slurm generation.

---

## Architecture

### Cluster Layout (per generation)

Each BurstLab environment provisions:

| Component | Details |
|-----------|---------|
| **VPC** | Simulates campus network — private subnets, NAT gateway, internet gateway |
| **Head node** | 1× t3.medium (or similar) — runs slurmctld, slurmdbd, munge |
| **Compute nodes** | 2–4× t3.small — "on-prem" static compute nodes running slurmd |
| **Burst partition** | Pre-configured AWS burst partition using Plugin v2, ready to launch cloud nodes |
| **Shared storage** | Small EFS or NFS export from head node for /home and Slurm state |

This is intentionally small and cheap. The point is configuration correctness, not performance benchmarking. Real workloads are optional but supported (a simple MPI hello-world or short GROMACS run that visibly bursts is a powerful demo).

### Parallel IaC Implementations

Every generation is implemented in **both**:

1. **Terraform** — HPC community standard; most Research IT teams know it
2. **AWS CDK (TypeScript)** — AWS-native; preferred by some SAs and customers already in the AWS ecosystem

Both produce identical clusters. The choice is the customer's preference, not a technical decision.

---

## Slurm Generations

The key insight: we don't need to support every Slurm point release. We target the **inflection points** where cloud integration semantics changed materially.

### Generation 1: "Classic Power Save" — Slurm 22.05.x on CentOS 8 ← START HERE

**Why this matters:** This is where most university pain lives right now. CentOS 8 is EOL (repos at vault.centos.org), Slurm 22.05 uses the traditional `SuspendProgram`/`ResumeProgram` model, and the Plugin v2 configuration is well-understood but fiddly. The TCU engagement falls in this generation.

| Parameter | Value |
|-----------|-------|
| OS | CentOS 8 (vault.centos.org mirrors) |
| Slurm | 22.05.x |
| Plugin | AWS Plugin for Slurm v2 (latest compatible) |
| Cloud model | `SuspendProgram` / `ResumeProgram` scripts |
| Node definitions | Static in `slurm.conf` — all burst nodes pre-enumerated |
| Key config | `PrivateData=cloud`, `SuspendTime`, `ResumeTimeout`, `SuspendTimeout` |
| Known issues | CentOS 8 EOL repo paths, `serializer/json` may or may not be needed depending on exact 22.05 patch level, `SelectType` must be consistent |

**Key files to get right:**
- `slurm.conf` — with cloud burst partition, power save directives, node definitions
- `partitions.json` — Plugin v2 partition configuration (instance types, subnets, IAM)
- `slurm_plugin.conf` — Plugin v2 global settings
- Munge key distribution
- AWS IAM roles and instance profiles for burst nodes

### Generation 2: "Reworked Cloud Integration" — Slurm 23.11.x on Rocky 8/9

**What changed:** Dynamic node registration, reworked `SuspendTime` and node state semantics, cloud nodes become more first-class. Configs from Gen 1 don't carry over cleanly.

| Parameter | Value |
|-----------|-------|
| OS | Rocky 8 or Rocky 9 |
| Slurm | 23.11.x |
| Plugin | AWS Plugin for Slurm v2 (version TBD based on compatibility) |
| Cloud model | Updated power save with dynamic node support |
| Key changes from Gen 1 | Node state handling, `SlurmctldParameters` options, possible `configless` mode |

### Generation 3: "Stateless Direction" — Slurm 24.05.x on Rocky 9

**What changed:** `slurm.conf` no longer needs to enumerate every possible burst node. This is the cleanest bursting model and what we'd *want* schools to target, but requires modern Slurm.

| Parameter | Value |
|-----------|-------|
| OS | Rocky 9 |
| Slurm | 24.05.x |
| Plugin | AWS Plugin for Slurm v2 (latest) |
| Cloud model | Stateless — no pre-enumerated cloud nodes |
| Key changes from Gen 2 | Simplified `slurm.conf`, reduced config surface area |

### Future: CentOS 7 Backport

Once Rocky/CentOS 8 is working, we may backport Gen 1 to CentOS 7 for schools still running it. This is a separate effort due to Python 2 vs 3, older system libraries, and additional EOL mirror gymnastics.

---

## Repository Structure

```
burstlab/
├── README.md
├── docs/
│   ├── architecture.md          # Cluster architecture diagrams
│   ├── generations.md           # Slurm generation details and rationale
│   ├── quickstart.md            # "Deploy your first BurstLab in 15 minutes"
│   └── sa-guide.md              # SA-facing guide: how to use BurstLab with customers
│
├── terraform/
│   ├── modules/
│   │   ├── vpc/                 # VPC, subnets, NAT, security groups
│   │   ├── head-node/           # Head node EC2 + config
│   │   ├── compute-nodes/       # Static "on-prem" compute nodes
│   │   ├── shared-storage/      # EFS or NFS
│   │   ├── iam/                 # Roles and instance profiles for bursting
│   │   └── burst-config/        # Plugin v2 configuration files
│   │
│   └── generations/
│       ├── gen1-slurm2205-centos8/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   ├── outputs.tf
│       │   ├── terraform.tfvars.example
│       │   └── configs/         # slurm.conf, partitions.json, etc.
│       ├── gen2-slurm2311-rocky/
│       └── gen3-slurm2405-rocky9/
│
├── cdk/
│   ├── package.json
│   ├── tsconfig.json
│   ├── lib/
│   │   ├── constructs/
│   │   │   ├── burstlab-vpc.ts
│   │   │   ├── burstlab-head-node.ts
│   │   │   ├── burstlab-compute-nodes.ts
│   │   │   ├── burstlab-shared-storage.ts
│   │   │   ├── burstlab-iam.ts
│   │   │   └── burstlab-burst-config.ts
│   │   │
│   │   └── stacks/
│   │       ├── gen1-slurm2205-centos8-stack.ts
│   │       ├── gen2-slurm2311-rocky-stack.ts
│   │       └── gen3-slurm2405-rocky9-stack.ts
│   │
│   └── configs/                 # Shared Slurm config templates
│       ├── gen1/
│       ├── gen2/
│       └── gen3/
│
├── configs/                     # Canonical Slurm configs (source of truth)
│   ├── gen1-slurm2205-centos8/
│   │   ├── slurm.conf.tpl
│   │   ├── partitions.json.tpl
│   │   ├── slurm_plugin.conf.tpl
│   │   ├── cgroup.conf
│   │   └── install-slurm.sh     # CentOS 8 Slurm 22.05 install script
│   ├── gen2-slurm2311-rocky/
│   └── gen3-slurm2405-rocky9/
│
├── scripts/
│   ├── validate-cluster.sh      # Post-deploy validation: sinfo, scontrol, test job
│   ├── demo-burst.sh            # Submit a job that triggers bursting
│   └── teardown.sh              # Clean shutdown
│
└── ami/                         # Optional: Packer templates for pre-baked AMIs
    ├── centos8-slurm2205.pkr.hcl
    ├── rocky8-slurm2311.pkr.hcl
    └── rocky9-slurm2405.pkr.hcl
```

---

## Generation 1 Implementation Details

### CentOS 8 AMI Considerations

CentOS 8 reached EOL on December 31, 2021. Package repos moved to `vault.centos.org`. The AMI and install scripts must:

1. Use a CentOS 8 AMI (AWS Marketplace or community — verify availability)
2. Repoint repos from `mirrorlist` to `vault.centos.org` baseurl
3. Install EPEL from vault as well
4. This is annoying but it's exactly what customers deal with — having it solved in the reference is part of the value

```bash
# Fix CentOS 8 repos for EOL
sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*.repo
sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo
```

### Slurm 22.05 Installation

Build from source or use SchedMD RPMs. For CentOS 8:

```bash
# Dependencies
yum install -y rpm-build gcc openssl openssl-devel \
  munge munge-devel munge-libs readline-devel \
  pam-devel perl-ExtUtils-MakeMaker python3 \
  mariadb-server mariadb-devel

# Download Slurm 22.05 source
SLURM_VERSION="22.05.11"
wget https://download.schedmd.com/slurm/slurm-${SLURM_VERSION}.tar.bz2

# Build RPMs
rpmbuild -ta slurm-${SLURM_VERSION}.tar.bz2

# Install
yum localinstall /root/rpmbuild/RPMS/x86_64/slurm-*.rpm
```

### Plugin v2 Installation

```bash
# Clone the official plugin
git clone https://github.com/aws-samples/aws-plugin-for-slurm.git /opt/aws-plugin-for-slurm
cd /opt/aws-plugin-for-slurm
git checkout <appropriate-tag-for-22.05>

# Install Python dependencies
pip3 install boto3
```

### Key slurm.conf Directives for Gen 1 Bursting

```ini
# === Cluster Identity ===
ClusterName=burstlab-gen1
SlurmctldHost=head-node

# === Scheduler ===
SelectType=select/cons_tres
SelectTypeParameters=CR_Core

# === Accounting (required for Plugin v2) ===
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=head-node

# === Power Save / Cloud Bursting ===
PrivateData=cloud
ResumeProgram=/opt/aws-plugin-for-slurm/resume_nodes.sh
SuspendProgram=/opt/aws-plugin-for-slurm/suspend_nodes.sh
ResumeTimeout=600
SuspendTimeout=120
SuspendTime=300
ResumeRate=10
SuspendRate=10
TreeWidth=65535

# === On-Prem Compute Nodes ===
NodeName=compute-[01-04] CPUs=2 RealMemory=3500 State=IDLE
PartitionName=local Nodes=compute-[01-04] Default=YES MaxTime=INFINITE State=UP

# === AWS Burst Nodes (pre-enumerated for Gen 1) ===
NodeName=burst-[001-100] CPUs=4 RealMemory=15000 State=CLOUD Weight=100
PartitionName=cloud Nodes=burst-[001-100] Default=NO MaxTime=4:00:00 State=UP

# === Hybrid Partition (optional: spans both) ===
PartitionName=all Nodes=compute-[01-04],burst-[001-100] Default=NO MaxTime=INFINITE State=UP
```

### Plugin v2 partitions.json (Gen 1)

```json
{
  "Partitions": [
    {
      "PartitionName": "cloud",
      "NodeGroups": [
        {
          "NodeGroupName": "burst-ondemand",
          "MaxNodeCount": 100,
          "Region": "${AWS_REGION}",
          "Networking": {
            "PlacementGroupStrategy": "cluster",
            "SubnetIds": ["${SUBNET_ID}"]
          },
          "ComputeResource": {
            "InstanceType": "c5.xlarge",
            "KeyName": "${KEY_NAME}",
            "IamInstanceProfile": "${INSTANCE_PROFILE_ARN}"
          },
          "CustomLaunchTemplateId": "${LAUNCH_TEMPLATE_ID}",
          "Tags": [
            {"Key": "Project", "Value": "burstlab"},
            {"Key": "Generation", "Value": "gen1"},
            {"Key": "Environment", "Value": "demo"}
          ]
        }
      ]
    }
  ]
}
```

### IAM Requirements

**Head node role** (or IAM user if simulating true on-prem with no instance role):
- `ec2:CreateFleet`
- `ec2:RunInstances`
- `ec2:TerminateInstances`
- `ec2:CreateTags`
- `ec2:DescribeInstances`
- `ec2:DescribeInstanceStatus`
- `iam:PassRole` (scoped to burst node role ARN)
- `iam:CreateServiceLinkedRole`

**Burst node instance profile:**
- Minimal — just enough to register with Slurm controller
- CloudWatch Logs (optional, for debugging)

### Post-Deploy Validation Script

```bash
#!/bin/bash
# validate-cluster.sh — run after deploy to confirm everything works

echo "=== Checking Slurm services ==="
systemctl is-active slurmctld
systemctl is-active slurmdbd
systemctl is-active munge

echo "=== Cluster info ==="
sinfo
scontrol show partition
scontrol show nodes | head -40

echo "=== Test local job ==="
sbatch --partition=local --wrap="hostname && sleep 5"
sleep 10
squeue

echo "=== Test burst job (will trigger cloud node) ==="
sbatch --partition=cloud --wrap="hostname && sleep 30"
squeue
echo "Watch for CLOUD nodes transitioning to IDLE..."
watch -n 5 sinfo
```

---

## Development Workflow

### Phase 1: Gen 1 Terraform (start here)
1. VPC module
2. Head node with Slurm 22.05 installed via user-data / cloud-init
3. Compute nodes joining the cluster
4. EFS for shared home
5. Plugin v2 installed and configured
6. Validate: `sinfo` shows local + cloud partitions, local jobs run, burst jobs trigger EC2

### Phase 2: Gen 1 CDK (parallel port)
1. Port VPC, head node, compute, storage, IAM constructs
2. Share the same `configs/gen1-*` templates
3. Validate identical cluster behavior

### Phase 3: Gen 2 + Gen 3
1. Use Gen 1 as template, swap OS AMI and Slurm version
2. Update `slurm.conf` for generation-specific directives
3. Adjust Plugin v2 config as needed

### Optional: Packer AMIs
If cloud-init scripts take too long (building Slurm from source is ~10 min), pre-bake AMIs with Packer. This also better simulates real environments where Slurm is pre-installed.

---

## Design Principles

1. **Correctness over cleverness.** Every config file should be something a university sysadmin can read and understand. No magic.
2. **Ephemeral by default.** `terraform destroy` / `cdk destroy` cleans up everything. No orphaned resources.
3. **Match reality.** Use CentOS 8 with broken repos, not some idealized image. The point is to show it working in the messy conditions customers actually have.
4. **Configs are the product.** The IaC is scaffolding. The real value is the known-good `slurm.conf`, `partitions.json`, IAM policies, and security groups for each generation.
5. **Separate concerns.** IaC provisions infrastructure. Shell scripts install and configure software. Config templates are parameterized but readable.
