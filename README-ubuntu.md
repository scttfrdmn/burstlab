# Ubuntu Generations — Quick Start

BurstLab includes two Ubuntu LTS generations:

- **Gen 4**: Ubuntu 22.04 LTS (Jammy) + Slurm 23.11
- **Gen 5**: Ubuntu 24.04 LTS (Noble) + Slurm 24.05

These generations are functionally identical to the corresponding Rocky generations
(Gen 2 and Gen 3), with OS-specific adaptations:

## Key Differences from Rocky Generations

### Package Management
- **Package manager**: `apt-get` (not `dnf`)
- **Package suffixes**: `-dev` (not `-devel`)
  - Example: `libssl-dev` not `openssl-devel`
- **Repo management**: No CRB/powertools equivalent needed; `universe` repo enabled by default

### System Paths
- **Environment files**: `/etc/default/` (not `/etc/sysconfig/`)
- **Shell for system users**: `/usr/sbin/nologin` (not `/sbin/nologin`)
- **PAM modules**: `/usr/lib/x86_64-linux-gnu/security` (not `/usr/lib64/security`)

### Security
- **MAC system**: AppArmor (not SELinux)
  - Slurm runs unconfined (no AppArmor profiles exist)
  - AppArmor left enabled for system daemons
- **Firewall**: `ufw` (not `firewalld`)
  - BurstLab disables ufw in favor of VPC security groups

### SSH Access
- **SSH user**: `ubuntu` (not `rocky`)
- Connect with: `ssh -i ~/.ssh/burstlab-key.pem ubuntu@<head_node_public_ip>`

### FSx Lustre
AWS does not publish Lustre client packages for Ubuntu LTS, so the node init scripts
**automatically install** a compatible client (Lustre 2.17.53) from
[burstlab-lustre](https://github.com/scttfrdmn/burstlab-lustre) at boot on both Ubuntu
generations.

- **EFS workloads**: ✅ Fully functional
- **FSx workloads**: 🧪 Client auto-installed; full Scenario 4 not yet re-validated on Ubuntu

See the [support matrix](docs/support-matrix.md) for the authoritative status.

## Build and Deploy

### Gen 4 (Ubuntu 22.04 + Slurm 23.11)

```bash
# Build AMI
cd ami/
AWS_PROFILE=aws packer build ubuntu2204-slurm2311.pkr.hcl

# Get AMI ID
AMI_ID=$(aws ec2 describe-images --owners self \
  --filters 'Name=name,Values=burstlab-gen4-*' \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text --profile aws)

# Deploy cluster
cd ../terraform/generations/gen4-slurm2311-ubuntu2204/
cat > terraform.tfvars << EOF
key_name        = "burstlab-key"
head_node_ami   = "$AMI_ID"
EOF

terraform init
AWS_PROFILE=aws terraform apply

# SSH to head node (note: ubuntu user, not rocky)
ssh -i ~/.ssh/burstlab-key.pem ubuntu@$(terraform output -raw head_node_public_ip)
```

### Gen 5 (Ubuntu 24.04 + Slurm 24.05)

```bash
# Build AMI
cd ami/
AWS_PROFILE=aws packer build ubuntu2404-slurm2405.pkr.hcl

# Get AMI ID
AMI_ID=$(aws ec2 describe-images --owners self \
  --filters 'Name=name,Values=burstlab-gen5-*' \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text --profile aws)

# Deploy cluster
cd ../terraform/generations/gen5-slurm2405-ubuntu2404/
cat > terraform.tfvars << EOF
key_name        = "burstlab-key"
head_node_ami   = "$AMI_ID"
EOF

terraform init
AWS_PROFILE=aws terraform apply

# SSH to head node (note: ubuntu user, not rocky)
ssh -i ~/.ssh/burstlab-key.pem ubuntu@$(terraform output -raw head_node_public_ip)
```

## Validation and Demo

The same validation and demo scripts work on all five generations:

```bash
# On head node (as ubuntu):
bash /opt/slurm/etc/validate-cluster.sh
bash /opt/slurm/etc/demo-burst.sh
```

## When to Use Ubuntu Generations

- Customer is running Ubuntu 22.04 or 24.04 on their HPC cluster
- Academic research computing environments (Ubuntu is common)
- Cloud-native HPC teams standardized on Ubuntu
- Customer prefers Debian-based systems over RHEL/Rocky

See [docs/generations.md](docs/generations.md) for detailed comparison across all five generations.
