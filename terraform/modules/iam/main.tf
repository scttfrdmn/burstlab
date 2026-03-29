# =============================================================================
# IAM MODULE - BurstLab Gen 1
# =============================================================================
# Creates two IAM roles:
#
#   1. head_node_role  - Used by slurmctld/aws-plugin-for-slurm on the head node.
#      Needs EC2 Fleet/RunInstances to launch burst nodes, TerminateInstances to
#      drain them, DescribeInstances to track state, and PassRole to hand the
#      burst node role to new instances.
#
#   2. burst_node_role - Used by slurmd on each burst node.
#      Only needs DescribeTags so it can read its own Name tag and set the
#      Slurm node name. Also gets SSM for remote access without SSH keys.
#
# Both roles also attach AmazonSSMManagedInstanceCore so operators can
# get a shell via SSM Session Manager even if SSH keys are misconfigured.
# =============================================================================

# =============================================================================
# BURST NODE ROLE
# (created first so head node PassRole policy can reference its ARN)
# =============================================================================

# Trust policy - allows EC2 instances to assume this role.
# This is the standard EC2 instance profile trust relationship.
data "aws_iam_policy_document" "burst_node_assume_role" {
  statement {
    sid     = "EC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "burst_node" {
  name               = "${var.cluster_name}-burst-node-role"
  assume_role_policy = data.aws_iam_policy_document.burst_node_assume_role.json
  description        = "Role for BurstLab burst nodes - minimal EC2 permissions + SSM"

  tags = {
    Name       = "${var.cluster_name}-burst-node-role"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

# -----------------------------------------------------------------------------
# Burst node custom policy - DescribeTags only
# -----------------------------------------------------------------------------
# slurmd on each burst node must discover its Slurm node name at boot time.
# The aws-plugin-for-slurm sets the instance's Name tag to the Slurm node name
# (e.g., "cloud-burst-0"). The node's init script reads this tag via the EC2
# metadata service (InstanceMetadataTags=enabled in the launch template) or
# via DescribeTags as a fallback.
#
# Minimal permissions by design - burst nodes should not have any ability to
# launch, terminate, or describe other instances.
data "aws_iam_policy_document" "burst_node_permissions" {
  statement {
    sid    = "ReadOwnTags"
    effect = "Allow"
    actions = [
      # Needed to read the Name tag set by aws-plugin-for-slurm at launch time.
      # The tag contains the Slurm NodeName (e.g. "cloud-burst-0"), which slurmd
      # uses to register itself with slurmctld.
      "ec2:DescribeTags",
    ]
    resources = ["*"]
    # Note: DescribeTags doesn't support resource-level restrictions in IAM.
  }
}

resource "aws_iam_policy" "burst_node_permissions" {
  name        = "${var.cluster_name}-burst-node-policy"
  description = "Minimal policy for burst nodes: read EC2 tags to determine Slurm node name"
  policy      = data.aws_iam_policy_document.burst_node_permissions.json

  tags = {
    Name       = "${var.cluster_name}-burst-node-policy"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "burst_node_custom" {
  role       = aws_iam_role.burst_node.name
  policy_arn = aws_iam_policy.burst_node_permissions.arn
}

# AmazonSSMManagedInstanceCore - enables SSM Session Manager on burst nodes.
# Lets operators shell into burst nodes for debugging without needing SSH keys
# or a bastion. Critical for a learning platform where things will go wrong.
resource "aws_iam_role_policy_attachment" "burst_node_ssm" {
  role       = aws_iam_role.burst_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile - wraps the role so it can be attached to an EC2 instance.
resource "aws_iam_instance_profile" "burst_node" {
  name = "${var.cluster_name}-burst-node-profile"
  role = aws_iam_role.burst_node.name

  tags = {
    Name       = "${var.cluster_name}-burst-node-profile"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

# =============================================================================
# HEAD NODE ROLE
# =============================================================================

data "aws_iam_policy_document" "head_node_assume_role" {
  statement {
    sid     = "EC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "head_node" {
  name               = "${var.cluster_name}-head-node-role"
  assume_role_policy = data.aws_iam_policy_document.head_node_assume_role.json
  description        = "Role for BurstLab head node - EC2 Fleet for burst, PassRole, SSM"

  tags = {
    Name       = "${var.cluster_name}-head-node-role"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

# -----------------------------------------------------------------------------
# Head node custom policy
# -----------------------------------------------------------------------------
# Each permission here maps to a specific operation performed by
# aws-plugin-for-slurm or the Slurm power-saving scripts:
#
#   ec2:CreateFleet        - launch burst nodes via EC2 Fleet API (plugin-v2 default)
#   ec2:RunInstances       - fallback / direct launch path used by CreateFleet
#   ec2:TerminateInstances - terminate burst nodes when jobs finish (SuspendProgram)
#   ec2:CreateTags         - tag newly launched burst nodes with their Slurm NodeName
#   ec2:DescribeInstances  - check instance status after launch / during power-save
#   ec2:DescribeInstanceStatus - verify instance is running before Slurm marks it UP
#   ec2:ModifyInstanceAttribute - may be needed to adjust instance settings post-launch
#   iam:CreateServiceLinkedRole - EC2 Fleet requires the AWSServiceRoleForEC2Fleet SLR;
#                                 this lets Terraform / the plugin create it on first use
#   iam:PassRole           - CRITICAL: when launching burst nodes, the head node passes
#                            the burst node's IAM role to the new instances. Without this
#                            the RunInstances / CreateFleet call will fail with AccessDenied.
data "aws_iam_policy_document" "head_node_permissions" {
  statement {
    sid    = "SlurmEC2FleetOperations"
    effect = "Allow"
    actions = [
      "ec2:CreateFleet",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:CreateTags",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:ModifyInstanceAttribute",
    ]
    resources = ["*"]
    # Note: DescribeInstances/DescribeInstanceStatus don't support resource-level
    # restrictions. CreateFleet/RunInstances restrictions would require specifying
    # AMI and subnet ARNs - kept as * here for lab simplicity.
  }

  statement {
    sid    = "EC2FleetServiceLinkedRole"
    effect = "Allow"
    actions = [
      # EC2 Fleet uses the AWSServiceRoleForEC2Fleet service-linked role.
      # If it doesn't exist yet, this permission lets the API call create it.
      "iam:CreateServiceLinkedRole",
    ]
    resources = ["arn:aws:iam::*:role/aws-service-role/ec2fleet.amazonaws.com/AWSServiceRoleForEC2Fleet"]
  }

  statement {
    sid    = "PassRoleToBurstNodes"
    effect = "Allow"
    actions = [
      # The head node passes the burst node role to new instances at launch time.
      # Scoped to just the burst node role ARN - principle of least privilege.
      "iam:PassRole",
    ]
    resources = [aws_iam_role.burst_node.arn]
  }
}

resource "aws_iam_policy" "head_node_permissions" {
  name        = "${var.cluster_name}-head-node-policy"
  description = "Head node policy: EC2 Fleet for burst node lifecycle + PassRole to burst nodes"
  policy      = data.aws_iam_policy_document.head_node_permissions.json

  tags = {
    Name       = "${var.cluster_name}-head-node-policy"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "head_node_custom" {
  role       = aws_iam_role.head_node.name
  policy_arn = aws_iam_policy.head_node_permissions.arn
}

# AmazonSSMManagedInstanceCore - same rationale as for burst nodes.
# Extra useful on the head node since it's the control plane - if slurmctld
# crashes or SSH is misconfigured, SSM is the escape hatch.
resource "aws_iam_role_policy_attachment" "head_node_ssm" {
  role       = aws_iam_role.head_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile for the head node EC2 instance.
resource "aws_iam_instance_profile" "head_node" {
  name = "${var.cluster_name}-head-node-profile"
  role = aws_iam_role.head_node.name

  tags = {
    Name       = "${var.cluster_name}-head-node-profile"
    Project    = "burstlab"
    Generation = "gen1"
    ManagedBy  = "terraform"
  }
}
