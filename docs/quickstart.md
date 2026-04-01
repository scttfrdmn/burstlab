# Quickstart: Deploy Your First BurstLab Cluster

This guide walks you through building and deploying a complete Gen 1 BurstLab cluster from scratch — no prior HPC or AWS experience required. By the end you will have a running Slurm cluster with four compute nodes and cloud bursting configured.

**Total time: about 30-40 minutes** (most of that is waiting, not working).

---

## What You Will Build

```
Head node (public IP, SSH entry point)
  ├── slurmctld   — Slurm job scheduler
  ├── slurmdbd    — accounting database
  └── NAT gateway — routes compute/burst node internet traffic

Compute nodes × 4 (private IPs, no direct internet)
  └── slurmd      — runs your jobs

Burst nodes × up to 10 (launched automatically when jobs need them)
  └── slurmd      — same as compute nodes, but EC2 instances that appear/disappear
```

All nodes share two EFS-mounted filesystems:
- `/u` — home directories (alice's files live here)
- `/opt/slurm` — Slurm binaries, configs, and plugins

---

## Prerequisites

You need four things before starting.

### 1. AWS CLI configured

```bash
# Install: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html
aws --profile aws sts get-caller-identity
```

This should print your AWS account ID and user ARN. If it errors, run `aws configure --profile aws` first.

Your AWS account needs permission to create EC2 instances, VPCs, IAM roles, and EFS filesystems. An `AdministratorAccess` policy works. If you have a more restricted policy, see `terraform/modules/iam/main.tf` for the exact resources created.

### 2. Terraform >= 1.5

```bash
terraform version
# Should print: Terraform v1.5.x or newer
```

Install: https://developer.hashicorp.com/terraform/install

### 3. Packer >= 1.10

```bash
packer version
# Should print: Packer v1.10.x or newer
```

Install: https://developer.hashicorp.com/packer/install

### 4. An EC2 key pair in us-west-2

This is the SSH key you will use to connect to the cluster.

Check if you have one:

```bash
aws --profile aws ec2 describe-key-pairs \
  --region us-west-2 \
  --query 'KeyPairs[].KeyName' \
  --output text
```

If you need to create one:

```bash
aws --profile aws ec2 create-key-pair \
  --region us-west-2 \
  --key-name burstlab-key \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/burstlab-key.pem

chmod 400 ~/.ssh/burstlab-key.pem
```

Write down the key pair name (e.g. `burstlab-key`) — you will need it in Step 3.

---

## Step 1: Build the AMI

**Time: ~15-20 minutes**

The Packer build creates an AWS machine image (AMI) with Rocky Linux 8 and Slurm 22.05 pre-installed. Every cluster node boots from this image.

```bash
cd ami/
packer init .
packer build -var "aws_profile=aws" rocky8-slurm2205.pkr.hcl
```

While this runs (~15-20 minutes), Packer will:
1. Launch a temporary `m7a.xlarge` build instance (~$0.20 for the build time)
2. Install build tools and compile Slurm 22.05.11 from source
3. Install AWS CLI v2, EFS utilities, and Python dependencies for the Plugin
4. Create the AMI, then terminate the build instance automatically

On success, you will see:

```
==> Builds finished. The artifacts of successful builds are:
--> amazon-ebs.rocky8: AMIs were created:
us-west-2: ami-0abc1234def56789a
```

**Copy the AMI ID.** You need it in Step 3.

If you need to retrieve it later:
```bash
aws --profile aws ec2 describe-images \
  --region us-west-2 --owners self \
  --filters "Name=name,Values=burstlab-gen1-rocky8-*" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text
```

> **Build failures:** The most common cause is a network timeout during package downloads — just run `packer build` again. If Rocky Linux source AMI lookup fails, it is an AWS eventual-consistency issue; wait 30 seconds and retry.

---

## Step 2: Configure Terraform

**Time: ~2 minutes**

```bash
cd terraform/generations/gen1-slurm2205-rocky8/
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` in a text editor. Fill in two values:

```hcl
key_name      = "burstlab-key"            # your EC2 key pair name from the prerequisite step
head_node_ami = "ami-0abc1234def56789a"   # AMI ID from Step 1
```

Everything else has reasonable defaults. Leave them as-is.

---

## Step 3: Deploy the Cluster

**Time: ~5-8 minutes**

```bash
# Still in terraform/generations/gen1-slurm2205-rocky8/
terraform init
terraform plan    # Optional: review what will be created
terraform apply   # Type 'yes' when prompted
```

Terraform creates approximately 44 resources:
- VPC with 4 subnets across 2 availability zones
- Security groups, route tables, Internet Gateway
- IAM roles and instance profiles
- EFS filesystem with mount targets
- EC2 launch template for burst nodes
- Head node with a permanent (Elastic) IP address
- 4 compute node instances

When it finishes:

```
Outputs:

head_node_public_ip  = "54.123.45.67"
head_node_private_ip = "10.0.0.10"
efs_dns_name         = "fs-0abc1234.efs.us-west-2.amazonaws.com"
```

Write down `head_node_public_ip` — that is your SSH address.

---

## Step 4: Wait for Cluster Initialization

**Time: ~10-15 minutes**

The instances are running but still configuring themselves. SSH in and watch:

```bash
ssh -i ~/.ssh/burstlab-key.pem rocky@<head_node_public_ip>
```

> SSH may not respond for the first 1-2 minutes while the instance boots. If it times out, wait 30 seconds and try again.

Tail the init log:

```bash
sudo tail -f /var/log/burstlab-init.log
```

You will see it progress through 13 steps. The EFS mount step is the longest — it polls until EFS DNS propagates, which can take up to 10 minutes. This is normal. Let it run.

Wait until you see:

```
=== BurstLab head node init complete: Mon Mar 30 02:15:44 UTC 2026 ===

Cluster status:
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
local*       up   infinite      4   idle compute[01-04]
cloud        up    4:00:00     10  idle~ cloud-burst-[0-9]
```

Press `Ctrl+C` to stop tailing, then open a new shell for the next steps.

---

## Step 5: Validate the Cluster

```bash
bash /opt/slurm/etc/validate-cluster.sh
```

Expected output (all green):

```
=== System Services ===
  [PASS] munge is running
  [PASS] mariadb is running
  [PASS] slurmdbd is running
  [PASS] slurmctld is running

=== EFS Mounts ===
  [PASS] /u is mounted
  [PASS] /u is NFS/EFS type
  [PASS] /opt/slurm is mounted
  [PASS] /opt/slurm is NFS/EFS type

=== Slurm Cluster State ===
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
local*       up   infinite      4   idle compute[01-04]
cloud        up    4:00:00     10  idle~ cloud-burst-[0-9]
  [PASS] local partition is UP
  [PASS] cloud partition is UP
  [PASS] No compute nodes are DOWN

Results: 20 passed, 0 warnings, 0 failed
Cluster is ready. Run demo-burst.sh to test bursting.
```

The `idle~` state for cloud nodes is correct — it means the nodes are registered with Slurm but no EC2 instances exist yet. They launch on demand when jobs are submitted.

> **Compute nodes showing DOWN?** Give them 2-3 more minutes — they are still running their own init. Run `scontrol show node compute01` to see the reason.

---

## Step 6: Log In as Alice

Alice is the demo HPC user. Her home directory is on shared EFS storage so her files are accessible from any node in the cluster.

```bash
# SSH directly as alice (uses the same EC2 key pair as rocky)
ssh -i ~/.ssh/burstlab-key.pem alice@<head_node_public_ip>
```

Verify your environment:

```bash
whoami      # alice
echo $HOME  # /u/home/alice
sinfo       # shows the cluster partitions
```

---

## Step 7: Run Jobs

### Local job (runs immediately on a static compute node)

```bash
# As alice:
sbatch --partition=local --wrap="hostname && date" -o ~/test-local.out

# Check output after a few seconds:
cat ~/test-local.out
```

Expected output:
```
compute01
Mon Mar 30 02:20:15 UTC 2026
```

### Burst job (triggers an EC2 instance to launch)

```bash
sbatch --partition=cloud --wrap="hostname && date" -o ~/test-burst.out
```

Watch the burst lifecycle:

```bash
watch -n 5 sinfo
```

Over 2-3 minutes you will see the node transition:

```
# Immediately after submit — Slurm calls resume.py → EC2 CreateFleet API
cloud   up  4:00:00   1  alloc~  cloud-burst-0
cloud   up  4:00:00   9  idle~   cloud-burst-[1-9]

# ~2 minutes — EC2 instance running, slurmd registered
cloud   up  4:00:00   1  alloc   cloud-burst-0

# Job finishes — node idles, then powers down after ~6 minutes
cloud   up  4:00:00  10  idle~   cloud-burst-[0-9]
```

Check the result:

```bash
cat ~/test-burst.out
# cloud-burst-0
# Mon Mar 30 02:23:07 UTC 2026
```

### Interactive demo

For a narrated walkthrough with explanations at each step:

```bash
bash /opt/slurm/etc/demo-burst.sh
```

---

## Step 8: Tear Down

From your local machine:

```bash
cd terraform/generations/gen1-slurm2205-rocky8/
terraform destroy
# Type 'yes' to confirm
```

This destroys all Terraform-managed resources. Any running burst nodes are also terminated.

**Also delete the AMI** when you no longer need it (Terraform does not manage the AMI):

```bash
AMI_ID=$(aws --profile aws ec2 describe-images \
  --region us-west-2 --owners self \
  --filters "Name=name,Values=burstlab-gen1-rocky8-*" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)

SNAPSHOT_ID=$(aws --profile aws ec2 describe-images \
  --region us-west-2 --image-ids "$AMI_ID" \
  --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text)

aws --profile aws ec2 deregister-image --region us-west-2 --image-id "$AMI_ID"
aws --profile aws ec2 delete-snapshot --region us-west-2 --snapshot-id "$SNAPSHOT_ID"
echo "AMI and snapshot deleted."
```

---

## Troubleshooting

| Symptom | What to check |
|---|---|
| SSH times out for more than 3 minutes | Instance is still booting. Check the EC2 console — wait for both Status Checks to pass. |
| Init log shows EFS mount retrying for 5+ minutes | Normal. EFS DNS propagation takes up to 10 minutes. Do not interrupt. |
| `sinfo` shows no cloud partition | `generate_conf.py` may have failed. Check: `grep -i "error\|fatal" /var/log/burstlab-init.log` |
| Compute nodes stuck in DOWN after 10 minutes | `scontrol show node compute01` — read the `Reason` field. Check `/var/log/burstlab-init.log` on that node via head node: `ssh compute01 sudo cat /var/log/burstlab-init.log` |
| Cloud node stuck in `alloc~` for more than 5 minutes | IAM issue or instance launch failure. `scontrol show node cloud-burst-0` then check EC2 console for failed launches. |
| Job stuck in PD (pending) with no node assigned | `scontrol show job <jobid>` — read the `Reason` field. |
| `squeue` shows job running but no output file | Check the job was submitted with an output path under `/u/home/alice/` so it writes to shared storage. |

If the init log shows `FATAL`:
```bash
sudo grep -A5 FATAL /var/log/burstlab-init.log
```

For service-level logs:
```bash
journalctl -u slurmctld --no-pager -n 50
journalctl -u slurmdbd  --no-pager -n 20
journalctl -u munge     --no-pager -n 20
```
