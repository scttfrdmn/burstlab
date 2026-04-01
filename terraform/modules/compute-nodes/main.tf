# =============================================================================
# COMPUTE NODES MODULE — BurstLab Gen 1
# =============================================================================
# Creates the simulated "on-prem" compute nodes (compute01, compute02, ...).
# These are always-running EC2 instances that represent the fixed capacity of
# a real on-prem HPC cluster. Jobs that can't fit here trigger cloud bursting.
#
# Naming convention: compute01, compute02, ... (1-indexed)
# The node_index is passed to UserData so each node registers itself with the
# correct Slurm NodeName.
#
# All nodes share:
#   - Same AMI as the head node (ensures Slurm version match)
#   - Same Munge key (shared secret for authentication)
#   - EFS mounts for /u and /opt/slurm
#   - No public IP — internet access goes through head node NAT
# =============================================================================

# -----------------------------------------------------------------------------
# Compute node instances (count-based)
# -----------------------------------------------------------------------------
# Using count (not for_each) because compute nodes are homogeneous and we want
# a simple integer variable (compute_node_count) to control the quantity.
# count.index is 0-based; we add 1 to get 1-based naming (compute01, compute02).
resource "aws_instance" "compute" {
  count = var.compute_node_count

  ami           = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name
  subnet_id     = var.subnet_id
  # Assign a deterministic static private IP so the head node's /etc/hosts
  # (built with cidrhost(onprem_cidr, i+10)) resolves compute01..N correctly.
  # compute01 → .10, compute02 → .11, etc.
  private_ip    = cidrhost(var.onprem_cidr, count.index + 10)

  vpc_security_group_ids = [var.sg_id]

  # Compute nodes don't need IAM permissions — they don't call AWS APIs.
  # They authenticate with Slurm via Munge (shared secret), not AWS IAM.
  # No instance profile attached.

  # No public IP — these nodes only communicate within the VPC.
  # Internet access (for yum updates etc.) routes through the head node NAT.

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true

    tags = {
      Name       = "${var.cluster_name}-compute${format("%02d", count.index + 1)}-root"
      Project    = "burstlab"
      Generation = "gen1"
      ManagedBy  = "terraform"
    }
  }

  # UserData runs once at first boot. Each compute node:
  #   1. Writes the Munge key and starts munge
  #   2. Mounts EFS (/u and /opt/slurm)
  #   3. Adds head node IP to /etc/hosts so Slurm can resolve slurmctld hostname
  #   4. Starts slurmd
  #
  # node_index is count.index + 1 (1-based) so compute01 gets node_index=1.
  # This is used in the init script to set the hostname: compute01, compute02...
  user_data = templatefile("${path.module}/../../../scripts/userdata/compute-node-init.sh.tpl", {
    cluster_name              = var.cluster_name
    node_index                = count.index + 1
    munge_key_b64             = var.munge_key_b64
    efs_dns_name              = var.efs_dns_name
    # The template uses head_node_ip (shorter name) — kept consistent with the
    # existing script convention.
    head_node_ip              = var.head_node_private_ip
    # compute_node_count and onprem_cidr are used by the template to build
    # /etc/hosts entries for all compute nodes so they resolve each other.
    compute_node_count        = var.compute_node_count
    onprem_cidr               = var.onprem_cidr
  })

  user_data_replace_on_change = true

  tags = {
    # Node name follows the convention in slurm.conf: compute01, compute02, ...
    # The init script sets the OS hostname to match this tag.
    Name       = "${var.cluster_name}-compute${format("%02d", count.index + 1)}"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
    Role       = "compute-node"
    # NodeIndex is stored as a tag for debugging — which EC2 instance is which node.
    NodeIndex  = tostring(count.index + 1)
  }
}
