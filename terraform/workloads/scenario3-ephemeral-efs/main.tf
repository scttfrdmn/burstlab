# =============================================================================
# SCENARIO 3 — Ephemeral EFS
# =============================================================================
# Grants head node and burst nodes the IAM permissions needed to create and
# destroy EFS filesystems at job runtime. The EFS filesystem itself is NOT
# created by Terraform — it is created and destroyed by Slurm job scripts.
#
# Prerequisites: base/ layer must be deployed first.
#
# What this layer does:
#   1. Attaches EFS lifecycle IAM policy to head node role (for job submission)
#   2. Attaches EFS lifecycle IAM policy to burst node role (for job execution)
#
# After applying, submit jobs via:
#   BURST_SUBNET_ID=$(terraform output -raw burst_subnet_id) \
#   EFS_SG_ID=$(terraform output -raw efs_sg_id) \
#   AWS_REGION=us-west-2 \
#     bash /opt/slurm/etc/workloads/jobs/scenario3/submit-chain.sh --granularity per-job

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region  = local.aws_region
  profile = var.aws_profile
}

data "terraform_remote_state" "cluster" {
  backend = "local"
  config  = { path = var.gen_state_path }
}

locals {
  # Cluster identity comes from the generation's outputs so the overlay works on
  # every generation (SSH user rocky / ubuntu / ec2-user). The try() fallbacks keep
  # generation states applied before these outputs existed working on Gen 1–3;
  # re-apply the generation root (outputs-only change) to pick them up.
  ssh_user     = try(data.terraform_remote_state.cluster.outputs.ssh_user, "rocky")
  aws_region   = coalesce(var.aws_region, try(data.terraform_remote_state.cluster.outputs.aws_region, null))
  cluster_name = coalesce(var.cluster_name, try(data.terraform_remote_state.cluster.outputs.cluster_name, null))

  head_node_role_name  = element(split("/", data.terraform_remote_state.cluster.outputs.head_node_role_arn), 1)
  burst_node_role_name = element(split("/", data.terraform_remote_state.cluster.outputs.burst_node_role_arn), 1)
  vpc_id               = data.terraform_remote_state.cluster.outputs.vpc_id
  # cloud_subnet_b_id is the burst (cloud) subnet — NOT the on-prem subnet.
  # Ephemeral EFS mount targets are created here to match real hybrid architecture.
  cloud_subnet_b_id    = data.terraform_remote_state.cluster.outputs.cloud_subnet_b_id
}

# Look up the EFS security group by name (created by the vpc module)
data "aws_security_group" "efs" {
  vpc_id = local.vpc_id
  filter {
    name   = "tag:Name"
    values = ["${local.cluster_name}-efs-sg"]
  }
}

# EFS lifecycle permissions for head node (submits the create/destroy jobs)
resource "aws_iam_role_policy" "head_node_efs_lifecycle" {
  name = "${local.cluster_name}-workloads-efs-lifecycle"
  role = local.head_node_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "EFSLifecycle"
      Effect = "Allow"
      Action = [
        "elasticfilesystem:CreateFileSystem",
        "elasticfilesystem:CreateMountTarget",
        "elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeMountTargets",
        "elasticfilesystem:DescribeMountTargetSecurityGroups",
        "elasticfilesystem:DeleteFileSystem",
        "elasticfilesystem:DeleteMountTarget",
        "elasticfilesystem:TagResource",
        "elasticfilesystem:ListTagsForResource",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeNetworkInterfaces"
      ]
      Resource = "*"
    }]
  })
}

# EFS lifecycle permissions for burst nodes (execute the create/destroy jobs)
resource "aws_iam_role_policy" "burst_node_efs_lifecycle" {
  name = "${local.cluster_name}-workloads-efs-lifecycle"
  role = local.burst_node_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "EFSLifecycle"
      Effect = "Allow"
      Action = [
        "elasticfilesystem:CreateFileSystem",
        "elasticfilesystem:CreateMountTarget",
        "elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeMountTargets",
        "elasticfilesystem:DescribeMountTargetSecurityGroups",
        "elasticfilesystem:DeleteFileSystem",
        "elasticfilesystem:DeleteMountTarget",
        "elasticfilesystem:TagResource",
        "elasticfilesystem:ListTagsForResource",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeNetworkInterfaces"
      ]
      Resource = "*"
    }]
  })
}
