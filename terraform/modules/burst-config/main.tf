# =============================================================================
# BURST CONFIG MODULE — BurstLab Gen 1
# =============================================================================
# Creates the EC2 Launch Template used by aws-plugin-for-slurm to launch
# burst nodes on demand.
#
# The launch template captures everything about a burst node's configuration:
#   - AMI (same as compute nodes — identical Slurm install)
#   - Instance type (m7a.2xlarge — matches compute nodes)
#   - IAM instance profile (burst node role — allows DescribeTags)
#   - Security group (burst_node_sg — intra-VPC only)
#   - Metadata options (InstanceMetadataTags=enabled — HOW slurmd gets its name)
#   - UserData (mounts EFS, sets hostname, starts slurmd)
#
# The launch template ID is passed to partitions.json, which is read by the
# aws-plugin-for-slurm on the head node when it calls EC2 Fleet.
# =============================================================================

# -----------------------------------------------------------------------------
# Burst node launch template
# -----------------------------------------------------------------------------
resource "aws_launch_template" "burst" {
  name        = "${var.cluster_name}-burst-node-lt"
  description = "Launch template for BurstLab burst nodes — used by aws-plugin-for-slurm EC2 Fleet calls"

  image_id      = var.ami_id
  instance_type = var.burst_node_instance_type
  key_name      = var.key_name

  # Attach the burst node IAM instance profile.
  # This gives slurmd the DescribeTags permission it needs to read its node name.
  iam_instance_profile {
    name = var.burst_node_instance_profile_name
  }

  # Security group — intra-VPC only, no public ingress.
  vpc_security_group_ids = [var.burst_node_sg_id]

  # ---------------------------------------------------------------------------
  # Instance Metadata Options — CRITICAL for node naming
  # ---------------------------------------------------------------------------
  # instance_metadata_tags = "enabled" makes EC2 instance tags available via
  # the Instance Metadata Service (IMDS) at:
  #   http://169.254.169.254/latest/meta-data/tags/instance/Name
  #
  # WHY this matters: aws-plugin-for-slurm sets the EC2 Name tag to the Slurm
  # node name (e.g., "cloud-burst-0") when launching burst nodes. The burst
  # node's init script reads this tag from IMDS to set its hostname and to
  # tell slurmd what NodeName to register with slurmctld.
  #
  # WITHOUT this setting, slurmd would register with the OS hostname (which is
  # an EC2-generated name like ip-10-0-2-5), not the Slurm node name, and
  # slurmctld would never match the node to its configured NodeName.
  #
  # http_tokens = "required" enforces IMDSv2 (token-based metadata access).
  # This is a security best practice — it prevents SSRF attacks from reading
  # instance metadata. The init script uses the two-step IMDSv2 token flow.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  # Root volume — 30 GB is enough for the OS and job scratch space.
  # Home dirs and Slurm binaries come from EFS mounts.
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  # UserData for burst nodes:
  #   1. Read node name from IMDS tags (requires InstanceMetadataTags=enabled)
  #   2. Set OS hostname to the Slurm node name
  #   3. Write Munge key and start munge
  #   4. Mount EFS (/u and /opt/slurm)
  #   5. Add head node IP to /etc/hosts
  #   6. Start slurmd — it will register with slurmctld using the correct NodeName
  #
  # base64encode() is required because launch template UserData must be base64.
  user_data = base64encode(templatefile("${path.module}/../../../scripts/userdata/burst-node-init.sh.tpl", {
    cluster_name              = var.cluster_name
    munge_key_b64             = var.munge_key_b64
    efs_dns_name              = var.efs_dns_name
    # The burst-node-init template uses head_node_ip (matching compute-node
    # convention). We accept head_node_private_ip as a variable name to be
    # explicit, then map it to what the template expects.
    head_node_ip              = var.head_node_private_ip
    aws_region                = var.aws_region
  }))

  # Tag burst node instances at launch. DO NOT set Name here.
  # resume.py sets Name=<slurm-node-name> (e.g., "aws-burst-0") via EC2 CreateFleet.
  # If Name is set in the launch template, the instance starts with the wrong name
  # and burst-node-init.sh reads it from IMDS before resume.py can correct it —
  # causing slurmd to register with the wrong node name and fail. Without a default
  # Name, the IMDS tag endpoint returns 404 until resume.py sets the correct name,
  # which causes the retry loop in burst-node-init.sh to wait as intended.
  tag_specifications {
    resource_type = "instance"
    tags = {
      Project    = "burstlab"
      Cluster    = var.cluster_name
      Generation = var.generation
      ManagedBy  = "terraform"
      Role       = "burst-node"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name       = "${var.cluster_name}-burst-node-root"
      Project    = "burstlab"
      Generation = var.generation
      ManagedBy  = "terraform"
    }
  }

  tags = {
    Name       = "${var.cluster_name}-burst-node-lt"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}
