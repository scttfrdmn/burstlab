# BurstLab Architecture

This document explains every design decision in the BurstLab Gen 1 network and infrastructure layout. The goal is that anyone reading this — an SA, a Research IT engineer, or a customer — can understand not just what was built, but why.

---

## Why Simulate On-Prem with AWS EC2?

HPC cloud bursting is a configuration problem, not a compute problem. The hard part is not running jobs in the cloud — it is getting `slurmctld` to recognize cloud nodes, getting burst nodes to register themselves correctly, and ensuring all the pieces (munge, accounting, power save scripts, IAM) are wired together consistently.

Every one of these problems can be reproduced and solved using EC2 instances. Simulating on-prem with AWS gives us:

**Reproducibility.** A known-good cluster can be deployed in any AWS account in under 20 minutes. There is no dependency on a customer's physical hardware, VPN access, or firewall rules.

**Safety.** We can experiment with breaking and fixing things without affecting a customer's production cluster. We can introduce the exact failures that TCU experienced — diverged `slurm.conf`, missing `serializer/json`, mismatched `SelectType` — and demonstrate the fixes.

**Portability.** An SA in Seattle can deploy the same cluster as an SA in Boston. The IaC is the complete specification of the environment.

**Accuracy.** The on-prem simulation is deliberately imperfect in the same ways real clusters are imperfect: CentOS 8 with broken EOL repos, Slurm built from source, non-standard install paths. This is intentional.

---

## Network Design

### Four Subnets

```
VPC 10.0.0.0/16
├── management  10.0.0.0/24  us-west-2a  — head node (public EIP)
├── on-prem     10.0.1.0/24  us-west-2a  — compute nodes (private)
├── cloud-a     10.0.2.0/24  us-west-2a  — burst nodes
└── cloud-b     10.0.3.0/24  us-west-2b  — burst nodes (second AZ)
```

The four-subnet design is not minimal — it is deliberately structured to mirror how real HPC cloud bursting architectures work:

**Management subnet** is the boundary between the simulated campus network and the outside world. The head node sits here with an Elastic IP for SSH access. In a real environment this maps to the site's DMZ or bastion subnet.

**On-prem subnet** simulates a private campus compute network. Nodes here have no public IPs and cannot initiate connections to the internet directly — they must route through the head node. This matches how compute nodes behave on virtually every real HPC cluster.

**Cloud subnet A and B** are where burst nodes land. Two subnets in two AZs serve two purposes: capacity availability (EC2 spot and on-demand pools are independent per AZ) and failure isolation (if us-west-2a has a capacity shortage, the EC2 Fleet request can fill from us-west-2b). In Plugin v2, both subnet IDs are listed in `partitions.json` and the Fleet request spans them automatically.

### Why the Head Node is the NAT (Not a NAT Gateway)

A standard AWS NAT Gateway would be simpler to operate, but using the head node as a NAT router is a deliberate choice:

1. **It mirrors real on-prem behavior.** HPC clusters almost universally route compute node internet traffic through the head or management node. An SA demonstrating this setup should be using the same topology the customer has.

2. **It is cheaper for a lab.** A NAT Gateway costs $0.045/hour plus $0.045/GB data processed, independent of usage. For a cluster that may sit idle for days between demos, this adds up. The head node instance is already running; NAT is a nearly-zero marginal cost.

3. **It is instructive.** When an SA or customer sees `iptables -t nat -L`, they understand exactly how the network works. A NAT Gateway is a black box.

The implementation uses standard Linux IP masquerade:

```bash
# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

# Masquerade outbound traffic from private subnets
iptables -t nat -A POSTROUTING -s 10.0.1.0/24 -o eth0 -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.0.2.0/24 -o eth0 -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.0.3.0/24 -o eth0 -j MASQUERADE
```

The head node EC2 instance has **source/destination check disabled** in Terraform. By default, AWS drops packets where the instance is neither source nor destination. Disabling this check allows the head node to forward packets on behalf of compute and burst nodes.

Route tables for the on-prem and cloud subnets have their default route pointing to the head node's primary ENI (`eni-xxxxxxxxxxxxxxxxx`). These routes are added by the head-node Terraform module after the instance is created (the ENI ID is not known until EC2 launch).

---

## EFS Design

### Why EFS for Both /home and /opt/slurm

Slurm has a hard requirement: the `slurm.conf` file must be **identical** on every node in the cluster. `slurmctld` hashes the config and distributes that hash; if a compute or burst node loads a different config, it will fail to start or refuse to communicate. (We disable hash checking with `DebugFlags=NO_CONF_HASH` for reasons explained in [slurm-gen1-deep-dive.md](slurm-gen1-deep-dive.md), but the underlying reason for config consistency remains valid.)

In real on-prem clusters this is solved with NFS. EFS is managed NFS — it handles the underlying storage, replication, and availability, and presents a standard NFS v4.1 interface to clients.

Two mount points on EFS:

**/home** — User home directories. All nodes (head, compute, burst) mount `/home` from EFS so that a user's files are accessible regardless of which node a job runs on. This is required for any non-trivial workload and expected by every researcher who uses the cluster.

**/opt/slurm** — The entire Slurm installation: binaries, libraries, configuration files, Plugin v2 scripts. This is the key architectural decision. When a burst node starts up, it mounts EFS at `/opt/slurm` and immediately has the correct `slurm.conf`, `partitions.json`, `config.json`, and the `slurmd` binary itself. There is no configuration management step, no S3 download, no user data complexity.

### First-Boot EFS Population

The Packer AMI installs Slurm to `/opt/slurm-baked/` — a path that is always present on local disk. `/opt/slurm/` is reserved as the EFS mount point.

On the head node's first boot, cloud-init:

1. Mounts EFS at `/opt/slurm`
2. Checks for a sentinel file `/opt/slurm/.burstlab-populated`
3. If the sentinel is absent, runs `rsync -a /opt/slurm-baked/ /opt/slurm/` to populate EFS from the baked binaries
4. Writes the sentinel file to prevent re-population on subsequent boots
5. Renders config templates (slurm.conf, partitions.json, etc.) and writes them to `/opt/slurm/etc/`
6. Copies the munge key to `/opt/slurm/etc/munge/munge.key` so compute nodes can retrieve it

On compute and burst nodes, cloud-init mounts EFS at `/opt/slurm` and that is all — the content is already there.

### EFS Mount Targets in All Four Subnets

EFS mount targets are created in all four subnets. This ensures that NFS connections are always local to the AZ — no cross-AZ EFS traffic. Without the `cloud-b` mount target, burst nodes launching in `us-west-2b` would either fail to mount or incur cross-AZ NFS latency and cost.

The EFS security group allows TCP 2049 (NFS) from the entire VPC CIDR (10.0.0.0/16). All nodes — head, compute, burst — are in this VPC and need NFS access.

---

## Head Node as NAT: Traffic Flow

When a compute or burst node sends a packet to an external destination (e.g., a yum repo at `mirror.centos.org`):

1. Node looks up its default route: `0.0.0.0/0 via 10.0.0.X` (head node's private IP, added by Terraform to the subnet's route table)
2. Packet arrives at the head node's eth0
3. Head node's IP forwarding is enabled (`net.ipv4.ip_forward=1`)
4. iptables POSTROUTING MASQUERADE rule rewrites the source IP to the head node's IP
5. Packet exits via the head node's primary ENI to the Internet Gateway
6. Return packet arrives at head node, NAT table reverses the translation, packet forwarded to the originating node

This same path applies to:
- Compute nodes downloading yum packages
- Burst nodes running `amazon-efs-utils` to mount EFS
- Slurm daemons making AWS API calls (e.g., `ec2:DescribeTags` from burst nodes)

Note that the head node itself reaches the internet directly through the Internet Gateway — its management subnet route table points `0.0.0.0/0` at the IGW, not at itself.

---

## Security Groups

BurstLab uses four security groups. All intra-cluster traffic uses the VPC CIDR (10.0.0.0/16) as the source range rather than individual SG references. This simplifies the rules and accurately reflects that all nodes are within the same trusted network — the same assumption a real on-prem cluster makes.

### Head Node SG

| Direction | Protocol | Port | Source/Dest | Reason |
|---|---|---|---|---|
| Inbound | TCP | 22 | 0.0.0.0/0 | SSH access for SAs and students |
| Inbound | All | All | 10.0.0.0/16 | All Slurm, Munge, EFS, srun traffic from cluster nodes |
| Outbound | All | All | 0.0.0.0/0 | AWS API (EC2 Fleet), yum repos, EFS |

The broad inbound rule from the VPC CIDR covers:
- **Slurm ports**: slurmctld (6817), slurmd (6818), slurmdbd (6819)
- **Munge**: port 988 (munge daemon uses a Unix socket locally; inter-node munge tokens are carried inside Slurm protocol messages, not as raw TCP)
- **NFS/EFS**: TCP 2049
- **srun I/O forwarding**: ephemeral ports (srun allocates ports dynamically)

In production, you would restrict SSH to a bastion or VPN CIDR. For a lab, `0.0.0.0/0` is acceptable and expected.

### Compute Node SG

| Direction | Protocol | Port | Source/Dest | Reason |
|---|---|---|---|---|
| Inbound | All | All | 10.0.0.0/16 | Slurm communication from slurmctld and srun |
| Outbound | All | All | 0.0.0.0/0 | Internet via head node NAT |

No public inbound traffic. Compute nodes have no public IP addresses.

### Burst Node SG

Identical to the compute node SG. Burst nodes have no public IPs and receive all communication from within the VPC.

### EFS SG

| Direction | Protocol | Port | Source/Dest | Reason |
|---|---|---|---|---|
| Inbound | TCP | 2049 | 10.0.0.0/16 | NFS from all cluster nodes |
| Outbound | All | All | 0.0.0.0/0 | Standard AWS SG requirement |

EFS mount targets do not initiate connections; the outbound rule is a formality required by AWS SG validation.

---

## IAM Design

Two IAM roles are created. The principle of least privilege is strictly applied — each role has only the permissions it needs for its specific function.

### Head Node Role

The head node runs `slurmctld` and the Plugin v2 resume/suspend scripts. It needs:

| Permission | Why |
|---|---|
| `ec2:CreateFleet` | Plugin v2 uses EC2 Fleet as the launch API. Fleet supports multi-AZ launch strategies and mixed instance types in a single call. |
| `ec2:RunInstances` | Called internally by CreateFleet; also used for direct launch fallback. |
| `ec2:TerminateInstances` | `suspend.py` terminates burst instances when `SuspendTime` expires. |
| `ec2:CreateTags` | `resume.py` tags new burst instances with their Slurm node name (`Name=aws-burst-0`). This tag is how the burst node knows its own identity at boot. |
| `ec2:DescribeInstances` | Plugin v2 checks instance state after launch to confirm nodes came up correctly. |
| `ec2:DescribeInstanceStatus` | Used to verify an instance is in `running` state before Slurm marks it `IDLE`. |
| `ec2:ModifyInstanceAttribute` | May be needed post-launch for certain instance configurations. |
| `iam:CreateServiceLinkedRole` | EC2 Fleet requires the `AWSServiceRoleForEC2Fleet` service-linked role. This permission allows creating it on first use if it does not exist. |
| `iam:PassRole` | **Critical.** When `CreateFleet` launches burst instances, the head node passes the burst node's IAM role to the new instances. Without `PassRole` scoped to the burst node role ARN, the launch call fails with `AccessDenied`. |
| `AmazonSSMManagedInstanceCore` | AWS managed policy. Enables SSM Session Manager — an escape hatch if SSH or Slurm configuration breaks on the head node. |

`iam:PassRole` is scoped to the burst node role ARN specifically (`resources = [aws_iam_role.burst_node.arn]`). This prevents the head node from passing any other role to EC2 instances — a common privilege escalation vector.

### Burst Node Role

Burst nodes run only `slurmd`. They need:

| Permission | Why |
|---|---|
| `ec2:DescribeTags` | The burst node reads its own `Name` tag to discover its Slurm node name (e.g., `aws-burst-0`). This tag is set by `resume.py` at launch time and read at boot via IMDS (with `InstanceMetadataTags=enabled` in the launch template) or via `DescribeTags` as a fallback. |
| `AmazonSSMManagedInstanceCore` | SSM access for debugging. Burst nodes have no SSH from the internet; SSM provides a shell without requiring bastion access or key management. |

`ec2:DescribeTags` does not support resource-level restrictions in IAM — the `resources = ["*"]` is unavoidable. This is a known AWS limitation, not a design gap.

Burst nodes deliberately cannot launch, terminate, or describe other instances. They cannot modify IAM or access S3. The attack surface of a compromised burst node is limited to reading EC2 tags.

---

## Packer AMI

### Why Pre-Bake vs Cloud-Init

Building Slurm 22.05.11 from source on a Rocky Linux 8 instance takes 8-12 minutes on an `m7a.xlarge` (`make -j4`). If this happened at every instance launch via cloud-init, burst node startup time would be unacceptable — Slurm's `ResumeTimeout` would need to be 15+ minutes, and the demo experience would be broken.

Pre-baking the AMI with Packer means:
- Burst nodes launch with Slurm already compiled and installed
- Cloud-init at boot only needs to mount EFS, copy the munge key, and start `slurmd` — a 30-60 second operation
- `ResumeTimeout=300` gives ample margin

A secondary benefit: the AMI is proof that the compilation worked. If `packer build` succeeds, the AMI contains a working `slurmd` binary. The Packer verification steps (`slurmd --version`, `slurmctld --version`) confirm this before the AMI is registered.

### What's in the AMI

The Packer template (`ami/rocky8-slurm2205.pkr.hcl`) produces an AMI with:

- Rocky Linux 8 base (CentOS 8 compatible; actively maintained repos — no vault redirect needed)
- Slurm 22.05.11 compiled and installed to `/opt/slurm-baked/`
- Systemd unit files for `slurmctld`, `slurmd`, `slurmdbd` with paths patched for `/opt/slurm-baked/`
- `SLURM_CONF=/opt/slurm/etc/slurm.conf` set in all unit files (EFS path)
- AWS CLI v2 (`/usr/local/bin/aws`)
- `amazon-efs-utils` (`/sbin/mount.efs`) for TLS EFS mounts
- `boto3` for Python scripts
- `munge`, `mariadb` (all nodes use the same AMI; role differentiation is at cloud-init)
- `slurm` user (UID 1001) and `munge` user (UID 985) with consistent IDs across all instances
- Required directories: `/var/log/slurm`, `/var/spool/slurm/ctld`, `/var/spool/slurm/d`, `/opt/slurm/etc`, `/var/lib/munge`
- SELinux set to `permissive` (enforcing requires a custom SELinux policy for Slurm, out of scope for Gen 1)
- `firewalld` disabled (VPC security groups provide the firewall)
- IMDSv2 enforced (`http_tokens=required`, hop limit 2)

### What's Done at Runtime (Cloud-Init)

The AMI is role-agnostic. The cloud-init script at first boot determines the node's role and configures accordingly:

**Head node:**
1. Set hostname to `headnode`
2. Mount EFS at `/home` and `/opt/slurm`
3. Populate `/opt/slurm/` from `/opt/slurm-baked/` (first boot only, guarded by sentinel)
4. Generate and install the munge key, write a copy to `/opt/slurm/etc/munge/munge.key`
5. Render `slurm.conf`, `slurmdbd.conf`, `partitions.json`, `config.json` from templates with Terraform-provided values
6. Initialize MariaDB and create the `slurm` accounting database
7. Start and enable: `munge`, `mariadb`, `slurmdbd`, `slurmctld`
8. Enable IP forwarding and configure iptables NAT masquerade
9. Run `generate_conf.py` to produce the burst node stanza and append to `slurm.conf`
10. Install the `change_state.py` cron for the `slurm` user
11. Write `/var/log/burstlab-init.log` with progress

**Compute nodes:**
1. Set hostname to `computeXX`
2. Wait for EFS to be available
3. Mount EFS at `/home` and `/opt/slurm`
4. Copy munge key from `/opt/slurm/etc/munge/munge.key` to `/etc/munge/munge.key`
5. Start and enable: `munge`, `slurmd`

**Burst nodes** (launched by Plugin v2, not Terraform):
1. Set hostname from EC2 Name tag via IMDS (`InstanceMetadataTags=enabled`)
2. Mount EFS at `/home` and `/opt/slurm`
3. Copy munge key from `/opt/slurm/etc/munge/munge.key` to `/etc/munge/munge.key`
4. Start `munge`, then `slurmd`
5. `slurmd` registers with `slurmctld` — node transitions from `CLOUD*` to `IDLE`

The entire burst node startup sequence (launch → cloud-init → slurmd register) completes in 90-120 seconds on `m7a.2xlarge`. `ResumeTimeout=300` accounts for variance.

---

## Cross-References

- How the slurm.conf power-save directives interact: [slurm-gen1-deep-dive.md](slurm-gen1-deep-dive.md)
- Plugin v2 config walkthrough and IAM deep dive: [plugin-v2-setup.md](plugin-v2-setup.md)
- Deploy steps: [quickstart.md](quickstart.md)
- SA demo flow: [sa-guide.md](sa-guide.md)
