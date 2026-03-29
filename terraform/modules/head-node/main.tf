# =============================================================================
# HEAD NODE MODULE — BurstLab Gen 1
# =============================================================================
# The head node is the control plane of the cluster. It runs:
#   - slurmctld   — Slurm controller daemon (job scheduling, node state)
#   - slurmdbd    — Slurm database daemon (job accounting via MariaDB)
#   - munge       — Authentication service (all Slurm API calls go through Munge)
#   - aws-plugin-for-slurm — Python plugin that calls EC2 Fleet to launch burst nodes
#   - iptables NAT — Routes internet traffic for on-prem compute and burst nodes
#
# The head node also acts as an NFS CLIENT for EFS (it mounts EFS and then
# writes config files to /opt/slurm/etc so all other nodes can read them).
# =============================================================================

# -----------------------------------------------------------------------------
# Head node EC2 instance
# -----------------------------------------------------------------------------
resource "aws_instance" "head_node" {
  ami           = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name
  subnet_id     = var.subnet_id

  # A static private IP breaks the Terraform circular dependency between:
  #   - slurm.conf (needs head node IP for SlurmctldHost)
  #   - burst launch template UserData (needs head node IP for /etc/hosts)
  # Both of those are rendered BEFORE the EC2 instance is created. By assigning
  # a known static IP (10.0.0.10 in the management subnet 10.0.0.0/24), we can
  # reference var.static_private_ip in the templates without creating a cycle.
  # 10.0.0.10 is chosen because .1-.9 are reserved by AWS in every subnet.
  private_ip = var.static_private_ip

  vpc_security_group_ids = [var.sg_id]

  iam_instance_profile = var.instance_profile_name

  # source_dest_check = false is REQUIRED for the head node to act as a NAT router.
  # By default, AWS drops packets where the source or destination IP doesn't match
  # the instance's own IP. When compute/burst nodes send packets destined for the
  # internet (0.0.0.0/0), the head node is the next hop — the packet source is
  # the compute node's IP, not the head node's. Disabling this check allows the
  # head node to forward those packets and apply iptables MASQUERADE.
  source_dest_check = false

  # Root volume — 50 GB is sufficient for the OS, Slurm build artifacts, and
  # MariaDB. User home directories and /opt/slurm live on EFS.
  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true

    tags = {
      Name       = "${var.cluster_name}-head-node-root"
      Project    = "burstlab"
      Generation = "gen1"
      ManagedBy  = "terraform"
    }
  }

  # UserData runs once at first boot. It:
  #   1. Writes the Munge key to /etc/munge/munge.key
  #   2. Mounts EFS (/home and /opt/slurm)
  #   3. Writes Slurm config files to /opt/slurm/etc/
  #   4. Enables iptables NAT masquerade for compute and burst subnets
  #   5. Starts munge, slurmdbd, slurmctld
  #   6. Installs the cron job that runs change_state.py every minute
  # Configs (slurm.conf, partitions.json, etc.) make UserData exceed the 16 KB
  # plain-text limit. AWS supports gzip-compressed UserData — cloud-init detects
  # and decompresses automatically. base64gzip renders → gzip → base64 in one call.
  user_data_base64 = base64gzip(templatefile("${path.module}/../../../scripts/userdata/head-node-init.sh.tpl", {
    cluster_name              = var.cluster_name
    munge_key_b64             = var.munge_key_b64
    efs_dns_name              = var.efs_dns_name
    efs_home_access_point_id  = var.efs_home_access_point_id
    efs_slurm_access_point_id = var.efs_slurm_access_point_id
    onprem_cidr               = var.onprem_cidr
    cloud_cidr_a              = var.cloud_cidr_a
    cloud_cidr_b              = var.cloud_cidr_b
    slurm_conf                = var.slurm_conf
    slurmdbd_conf             = var.slurmdbd_conf
    cgroup_conf               = var.cgroup_conf
    plugin_config_json        = var.plugin_config_json
    partitions_json           = var.partitions_json
    slurmdbd_db_password      = var.slurmdbd_db_password
    aws_region                = var.aws_region
    compute_node_count        = var.compute_node_count
  }))

  # Ensure instance replacement recreates the UserData (not just reboots).
  # Without this, changing UserData on an already-created instance has no effect.
  user_data_replace_on_change = true

  tags = {
    Name       = "${var.cluster_name}-head-node"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
    Role       = "head-node"
  }
}

# -----------------------------------------------------------------------------
# Elastic IP for the head node
# -----------------------------------------------------------------------------
# A static public IP is important for:
#   1. Consistent SSH access — the IP doesn't change if the instance is stopped/started.
#   2. DNS — you can create an A record pointing to the EIP.
#   3. Slurm config — slurm.conf SlurmctldHost can be the EIP or a hostname
#      that resolves to it (avoids reconfiguring the cluster on instance replacement).
resource "aws_eip" "head_node" {
  domain = "vpc"

  tags = {
    Name       = "${var.cluster_name}-head-node-eip"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

# Associate the EIP with the head node instance.
# Using association (not inline) so the EIP persists if the instance is rebuilt.
resource "aws_eip_association" "head_node" {
  instance_id   = aws_instance.head_node.id
  allocation_id = aws_eip.head_node.id
}

# =============================================================================
# NAT ROUTING — add default routes pointing to the head node ENI
# =============================================================================
# These routes are what makes the head node a NAT router.
# The route table resources (onprem_rtb, cloud_rtb) were created empty in the
# VPC module. Now that we have the head node's ENI ID, we can add the routes.
#
# WHY not use an IGW or NAT Gateway?
#   - An IGW would give compute/burst nodes direct internet access — that doesn't
#     model a real on-prem environment where all traffic goes through a gateway.
#   - A NAT Gateway costs ~$0.045/hr plus data processing — the head node NAT
#     is free (already paying for the EC2 instance).
#   - Using the head node as NAT is the classic HPC cluster pattern.

# Default route for on-prem compute subnet → head node ENI
resource "aws_route" "onprem_nat" {
  route_table_id         = var.onprem_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  # primary_network_interface_id is the ENI ID of the first (and only) network
  # interface on the head node instance.
  network_interface_id = aws_instance.head_node.primary_network_interface_id

  # This route depends on the instance being created first (implicit via reference).
}

# Default route for cloud burst subnets → head node ENI
resource "aws_route" "cloud_nat" {
  route_table_id         = var.cloud_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.head_node.primary_network_interface_id
}
