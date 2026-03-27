# BurstLab Gen 1 AMI

This directory contains the Packer template that builds the base AMI for all BurstLab nodes
(head, compute, and burst). The AMI is CentOS 8 with Slurm 22.05.11 compiled from source.

---

## Prerequisites

### Tools

| Tool | Minimum Version | Install |
|------|----------------|---------|
| Packer | 1.10.0 | `brew install packer` / [packer.io/downloads](https://developer.hashicorp.com/packer/downloads) |
| AWS CLI | 2.x | Pre-installed in the AMI; needed locally for credential verification |

Install the Packer Amazon plugin (one-time, per machine):

```bash
packer init centos8-slurm2205.pkr.hcl
```

### AWS Credentials

Packer needs permissions to:
- `ec2:DescribeImages`, `ec2:RunInstances`, `ec2:CreateImage`, `ec2:TerminateInstances`
- `ec2:CreateTags`, `ec2:DescribeInstances`, `ec2:StopInstances`
- `ec2:CreateSnapshot`, `ec2:DescribeSnapshots`

The build uses the `aws` CLI profile by default. Override with `-var aws_profile=myprofile`.

Verify your credentials before building:

```bash
aws --profile aws sts get-caller-identity
```

### VPC / Subnet

Packer launches a temporary EC2 instance in your default VPC. If your account has no default VPC
(or you want to build in a specific subnet), add to the `source "amazon-ebs"` block:

```hcl
vpc_id    = "vpc-xxxxxxxxxxxxxxxxx"
subnet_id = "subnet-xxxxxxxxxxxxxxxxx"
```

---

## Building the AMI

From this directory:

```bash
# Initialize plugins (first time only)
packer init centos8-slurm2205.pkr.hcl

# Validate the template
packer validate centos8-slurm2205.pkr.hcl

# Build
packer build centos8-slurm2205.pkr.hcl
```

### Common overrides

```bash
# Different region
packer build -var aws_region=us-east-1 centos8-slurm2205.pkr.hcl

# Different AWS profile
packer build -var aws_profile=myprofile centos8-slurm2205.pkr.hcl

# Use a larger instance for faster compile
packer build -var instance_type=c7a.2xlarge centos8-slurm2205.pkr.hcl

# Use a var file
packer build -var-file=my.pkrvars.hcl centos8-slurm2205.pkr.hcl
```

Example `my.pkrvars.hcl`:

```hcl
aws_region    = "us-east-1"
aws_profile   = "burstlab-build"
instance_type = "c7a.2xlarge"
```

---

## Expected Build Time

| Phase | Approximate Time |
|-------|----------------|
| Instance launch + SSH ready | 2–3 min |
| Repo fix + dnf installs | 5–8 min |
| Slurm compile (`make -j4` on m7a.xlarge) | 5–8 min |
| AWS CLI + efs-utils install | 3–5 min |
| AMI snapshot creation | 3–5 min |
| **Total** | **~20–30 min** |

Using a `c7a.2xlarge` (8 vCPUs) cuts the compile step to ~3 min and reduces total time to ~15 min.

---

## After the Build

Packer prints the AMI ID at the end of a successful build:

```
==> Builds finished. The artifacts of successful builds are:
--> amazon-ebs.centos8: AMIs were created:
us-west-2: ami-0xxxxxxxxxxxxxxxx
```

### 1. Record the AMI ID

Add it to your Terraform variables file:

```bash
# terraform/terraform.tfvars
echo 'base_ami_id = "ami-0xxxxxxxxxxxxxxxx"' >> ../terraform/terraform.tfvars
```

Or set it directly in `terraform/variables.tf` as the default for `base_ami_id`.

### 2. Verify the AMI (optional)

```bash
aws ec2 describe-images \
  --image-ids ami-0xxxxxxxxxxxxxxxx \
  --query 'Images[0].{Name:Name,State:State,Tags:Tags}' \
  --output table
```

### 3. Proceed with Terraform

```bash
cd ../terraform
terraform init
terraform plan
terraform apply
```

---

## What is Baked In

| Component | Path | Notes |
|-----------|------|-------|
| Slurm 22.05.11 binaries | `/opt/slurm-baked/` | Built from source, `--prefix=/opt/slurm-baked` |
| Slurm systemd units | `/etc/systemd/system/slurm*.service` | Paths patched; units NOT enabled |
| AWS CLI v2 | `/usr/local/bin/aws` | Official bundled installer |
| amazon-efs-utils | `/sbin/mount.efs` | Built from source |
| boto3 | Python site-packages | For burst node scripts |
| MariaDB client + server + devel | system | slurmdbd uses this on head node |
| munge user/group | UID/GID 985 | Pinned for consistent auth across nodes |
| slurm user/group | UID/GID 1001 | Pinned for NFS/EFS ownership consistency |

## What is NOT Baked In

| Item | Where it comes from |
|------|-------------------|
| `slurm.conf` | EFS mount at `/opt/slurm/etc/slurm.conf`, written by head node cloud-init |
| `munge.key` | Generated on head node, distributed to compute nodes via EFS |
| Node role (head/compute/burst) | Determined at boot by cloud-init via instance tags |
| Slurm enabled/started | cloud-init enables the correct service(s) per role |
| MariaDB started/configured | Head node cloud-init only |

---

## Key Design Decisions

**Why `/opt/slurm-baked/` and not `/opt/slurm/`?**

`/opt/slurm/` is the EFS mount point. All nodes mount EFS there at boot. Having the baked
binaries at a separate path avoids the chicken-and-egg problem where the binary needed to
mount EFS is itself on EFS.

On head node first boot: `rsync /opt/slurm-baked/ → EFS`, then mount EFS at `/opt/slurm`.
On compute/burst nodes: mount EFS at `/opt/slurm` directly (binaries come from EFS).

**Why build from source instead of RPMs?**

The Slurm RPM spec does not cleanly support `--prefix` overrides via `--define`. Building
from source with `./configure --prefix=...` gives a clean install under `/opt/slurm-baked/`
with no files leaking to `/usr/` or `/etc/`.

**Why CentOS 8 and not CentOS Stream / AlmaLinux / Rocky?**

BurstLab Gen 1 targets the CentOS 8 ecosystem for compatibility with existing HPC site configs.
The repo vault fix makes the image buildable. Future generations should migrate to AlmaLinux 8
or Rocky Linux 8, which have active update repositories and are binary-compatible with CentOS 8.

---

## Troubleshooting

**`dnf makecache` fails with "Failed to download metadata"`**

The vault.centos.org sed commands did not match all repo files. Check:

```bash
grep -r baseurl /etc/yum.repos.d/
```

All `baseurl=` values should point to `vault.centos.org`.

**`./configure` fails with "munge not found"`**

The `munge-devel` package did not install. Verify PowerTools repo is enabled:

```bash
dnf repolist | grep PowerTools
```

**Packer SSH timeout during instance launch**

Add `ssh_timeout = "10m"` to the source block. The default is 5 minutes, which can be tight
in regions with slower instance launch times.

**AMI shows in `us-west-2` but you need it in another region**

Copy the AMI:

```bash
aws ec2 copy-image \
  --source-region us-west-2 \
  --source-image-id ami-0xxxxxxxxxxxxxxxx \
  --region us-east-1 \
  --name "burstlab-gen1-centos8-slurm22.05.11-copy"
```
