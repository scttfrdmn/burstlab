# Quickstart: Deploy Your First BurstLab in 15 Minutes

This guide walks through deploying a complete Gen 1 BurstLab cluster: CentOS 8, Slurm 22.05.11, and the AWS Plugin for Slurm v2 pre-configured for cloud bursting.

Total time: 10-15 minutes for the Packer AMI build, then 3-5 minutes for Terraform.

---

## Prerequisites

Before starting, confirm:

- **AWS CLI** configured with a profile named `aws` pointing to `us-west-2`
  ```bash
  aws --profile aws sts get-caller-identity
  # Should return your account ID and user/role ARN
  ```

- **Terraform** >= 1.5
  ```bash
  terraform version
  # Terraform v1.5.x or newer
  ```

- **Packer** >= 1.10
  ```bash
  packer version
  # Packer v1.10.x or newer
  ```

- **An EC2 key pair** in `us-west-2` (you will need the key pair name and the `.pem` file path)
  ```bash
  aws --profile aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output text
  ```

- **IAM permissions** sufficient to create EC2 instances, VPC resources, IAM roles, and EFS filesystems. The deploying user or role needs broad enough permissions to provision everything Terraform creates. An AdministratorAccess policy works; see `terraform/modules/iam/main.tf` for the exact resources created.

---

## Step 1: Clone and Build the AMI

The Packer build compiles Slurm 22.05.11 from source on a CentOS 8 instance and produces a registered AMI. This is the most time-consuming step.

```bash
cd ami/
packer init .
packer build -var "aws_profile=aws" centos8-slurm2205.pkr.hcl
```

The build does the following on an `m7a.xlarge` build instance (see [architecture.md](architecture.md) for why we pre-bake vs cloud-init):
- Fixes CentOS 8 EOL repos to point at `vault.centos.org`
- Installs build dependencies
- Creates `slurm` (UID 1001) and `munge` (UID 985) users with pinned IDs
- Downloads and compiles Slurm 22.05.11 to `/opt/slurm-baked/`
- Installs AWS CLI v2, `amazon-efs-utils`, and `boto3`
- Sets SELinux permissive, disables `firewalld`
- Creates required spool, log, and config directories

On success, Packer prints:

```
==> Builds finished. The artifacts of successful builds are:
--> amazon-ebs.centos8: AMIs were created:
us-west-2: ami-XXXXXXXXXXXXXXXXX
```

**Note the AMI ID.** You will need it in the next step. You can also retrieve it later:
```bash
aws --profile aws ec2 describe-images \
  --owners self \
  --filters "Name=name,Values=burstlab-gen1-centos8-*" \
  --query 'Images[0].ImageId' \
  --output text
```

If the build fails, the most common causes are:
- CentOS 8 AMI not found in the region — try pinning `source_ami` to a known CentOS 8 AMI ID
- Network timeout during package downloads — retry; vault.centos.org can be slow
- Instance type not available — change `instance_type` to `m5.xlarge` or `c5.xlarge`

---

## Step 2: Configure Terraform

```bash
cd terraform/generations/gen1-slurm2205-centos8/
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. Required values:

```hcl
# The key pair name (not file path) of your EC2 key in us-west-2
key_name = "your-key-name"

# AMI ID from the Packer build in Step 1
head_node_ami = "ami-XXXXXXXXXXXXXXXXX"

# Optional: override the cluster name (default: "burstlab-gen1")
# cluster_name = "burstlab-gen1"

# Optional: restrict SSH access to your IP (default: 0.0.0.0/0)
# allowed_ssh_cidr = "203.0.113.10/32"
```

All other values have defaults that work for a standard lab deployment. Review `variables.tf` if you want to change instance types, node counts, or AWS region.

---

## Step 3: Deploy

```bash
terraform init
terraform plan    # Review what will be created
terraform apply   # Type 'yes' to confirm
```

Terraform creates approximately 40 resources:
- VPC with 4 subnets, route tables, Internet Gateway
- Security groups for head node, compute nodes, burst nodes, EFS
- IAM roles and instance profiles for head node and burst nodes
- EFS filesystem with mount targets in all 4 subnets
- EC2 launch template for burst nodes (with `InstanceMetadataTags=enabled`)
- Head node EC2 instance with Elastic IP
- 4 compute node EC2 instances
- All necessary route table entries

After `apply` completes, Terraform prints the outputs:

```
head_node_public_ip  = "54.X.X.X"
head_node_private_ip = "10.0.0.10"
efs_dns_name         = "fs-XXXXXXXX.efs.us-west-2.amazonaws.com"
burst_launch_template_id = "lt-XXXXXXXXXXXXXXXXX"
```

---

## Step 4: SSH In and Validate

The cluster is deployed but cloud-init still needs to finish configuring it. Give it 3-5 minutes before SSHing in, or SSH in immediately and tail the init log:

```bash
ssh -i ~/.ssh/your-key.pem centos@<head_node_public_ip>
sudo tail -f /var/log/burstlab-init.log
```

Wait until you see:

```
[burstlab-init] BurstLab Gen 1 initialization complete.
```

Then verify the cluster state:

```bash
# Check that core services are running
systemctl is-active munge mariadb slurmdbd slurmctld

# Check EFS mounts
mountpoint /home && mountpoint /opt/slurm

# Check cluster state
sinfo
```

Expected `sinfo` output:

```
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
local*       up   infinite      4   idle compute[01-04]
cloud        up    4:00:00     10  cloud~ cloud-burst-[0-9]
```

The `cloud~` state means the cloud nodes are powered off (in Slurm's `CLOUD` state) and ready to burst. The `~` suffix indicates they are in power-saving mode.

If any services are not running, check the init log:

```bash
sudo cat /var/log/burstlab-init.log
# Also check individual service logs:
journalctl -u slurmctld --no-pager -n 50
journalctl -u slurmdbd --no-pager -n 20
```

You can also run the full validation script:

```bash
bash /opt/slurm/etc/validate-cluster.sh
```

This checks every component: munge, EFS, Plugin v2 files, `slurm.conf` directives, service states, and accounting configuration. It reports PASS/WARN/FAIL for each check.

---

## Step 5: Submit a Test Job

### Local Job (Static Compute Nodes)

```bash
# Submit a job to the local partition — runs on compute01-04
sbatch --partition=local --wrap="hostname && sleep 10"
squeue
```

Expected output:

```
JOBID PARTITION     NAME     USER ST       TIME  NODES NODELIST(REASON)
    1     local     wrap   centos  R       0:03      1 compute01
```

The job runs immediately — compute nodes are always IDLE and ready.

### Burst Job (Triggers EC2 Instance Launch)

```bash
# Submit a job to the cloud partition — triggers a burst node to launch
sbatch --partition=cloud --wrap="hostname && sleep 60"
```

Now watch Slurm's view of the cloud nodes:

```bash
watch -n 5 sinfo
```

You will see the node transition through states:

```
# Immediately after submit: Slurm calls resume.py → EC2 CreateFleet
PARTITION AVAIL  TIMELIMIT  NODES  STATE    NODELIST
cloud        up    4:00:00      1  alloc~   cloud-burst-0
cloud        up    4:00:00      9  cloud~   cloud-burst-[1-9]

# ~2 minutes: instance is running, slurmd registered
cloud        up    4:00:00      1  alloc    cloud-burst-0
cloud        up    4:00:00      9  cloud~   cloud-burst-[1-9]

# ~3 minutes: job running on the burst node
cloud        up    4:00:00      1  alloc    cloud-burst-0
```

After the job completes, the node transitions to `idle` and then, after `SuspendTime=350` seconds with no new jobs:

```
# Node powers down: suspend.py calls TerminateInstances
cloud        up    4:00:00     10  cloud~   cloud-burst-[0-9]
```

Check the job output:

```bash
cat slurm-1.out
# cloud-burst-0
```

The hostname confirms the job ran on the burst node, not a local compute node.

### Watching EC2 in Real Time

While the burst job is running, open the EC2 console (`us-west-2`) and filter by tag `Project=burstlab`. You should see a new instance named `cloud-burst-0` appear within 60-90 seconds of job submission.

The instance will terminate automatically after `SuspendTime` expires — you do not need to clean it up manually.

---

## Cleanup

When you are done with the cluster:

```bash
# From your local machine, in the terraform/generations/gen1-slurm2205-centos8/ directory
terraform destroy
# Type 'yes' to confirm
```

This destroys all Terraform-managed resources: VPC, EC2 instances, EFS filesystem, IAM roles, and security groups. Any burst node instances that are currently running will also be terminated (they are Terraform-managed via the launch template resource).

**Also deregister the Packer AMI** when you are done with it — Terraform does not manage the AMI:

```bash
# Get the AMI ID
AMI_ID=$(aws --profile aws ec2 describe-images \
  --owners self \
  --filters "Name=name,Values=burstlab-gen1-centos8-*" \
  --query 'Images[0].ImageId' \
  --output text)

# Get the snapshot ID (to delete after deregistering the AMI)
SNAPSHOT_ID=$(aws --profile aws ec2 describe-images \
  --image-ids $AMI_ID \
  --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' \
  --output text)

# Deregister the AMI
aws --profile aws ec2 deregister-image --image-id $AMI_ID

# Delete the backing snapshot
aws --profile aws ec2 delete-snapshot --snapshot-id $SNAPSHOT_ID
```

---

## Troubleshooting Quick Reference

| Symptom | First Check |
|---|---|
| `sinfo` shows no cloud partition | Did `generate_conf.py` run? Check `/var/log/burstlab-init.log`. |
| Cloud node stuck in `alloc~` forever | `ResumeTimeout` too short, or IAM issue. Check `scontrol show node cloud-burst-0` for reason. |
| `Authentication failure` in slurmd log | Munge key mismatch. Check that `/etc/munge/munge.key` on compute/burst nodes matches the head node. |
| `slurmctld` won't start | Check `journalctl -u slurmctld`. Common cause: `slurmdbd` not running yet (it takes a few seconds after MariaDB). |
| `sinfo` shows compute nodes as DOWN | Compute nodes may still be in cloud-init. Give them 2-3 minutes. Check `scontrol show node compute01` for reason. |
| Job stuck in `PD` (pending) | Run `scontrol show job <jobid>` and read the `Reason` field. |

For detailed troubleshooting, see [plugin-v2-setup.md](plugin-v2-setup.md#debugging-common-failures).
