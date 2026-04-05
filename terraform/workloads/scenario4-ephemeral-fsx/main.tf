# =============================================================================
# SCENARIO 4 — Ephemeral FSx Lustre
# =============================================================================
# Grants burst nodes the IAM permissions to create and destroy FSx Lustre
# filesystems linked to an S3 data repository. The FSx filesystem is NOT
# created by Terraform — it is created and destroyed by Slurm job scripts.
#
# Prerequisites: base/ layer must be deployed first.
#
# What this layer does:
#   1. Creates an S3 bucket for the FSx data repository (input + results)
#   2. Grants burst nodes FSx + S3 lifecycle permissions
#   3. Creates the FSx service-linked role if not already present
#
# After applying, submit jobs via:
#   S3_DATA_BUCKET=$(terraform output -raw s3_data_bucket) \
#   BURST_SUBNET_ID=$(terraform output -raw burst_subnet_id) \
#   FSX_SG_ID=$(terraform output -raw fsx_sg_id) \
#   AWS_REGION=us-west-2 FSX_STORAGE_GB=1200 \
#     bash /opt/slurm/etc/workloads/jobs/scenario4/submit-chain.sh \
#     --granularity per-job --s3-data-prefix my-dataset/

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

data "terraform_remote_state" "cluster" {
  backend = "local"
  config  = { path = var.gen_state_path }
}

locals {
  burst_node_role_name = element(split("/", data.terraform_remote_state.cluster.outputs.burst_node_role_arn), 1)
  head_node_role_name  = element(split("/", data.terraform_remote_state.cluster.outputs.head_node_role_arn), 1)
  vpc_id               = data.terraform_remote_state.cluster.outputs.vpc_id
  # cloud_subnet_b_id is the burst (cloud) subnet — FSx must be created here, not on the on-prem subnet
  cloud_subnet_b_id    = data.terraform_remote_state.cluster.outputs.cloud_subnet_b_id
}

# Look up the burst node security group (FSx must be in the same SG or a peered SG)
data "aws_security_group" "burst" {
  vpc_id = local.vpc_id
  filter {
    name   = "tag:Name"
    values = ["${var.cluster_name}-burst-node-sg"]
  }
}

# =============================================================================
# S3 BUCKET — FSx data repository (input data + results)
# =============================================================================

resource "aws_s3_bucket" "fsx_data" {
  bucket_prefix = "${var.cluster_name}-fsx-data-"
  force_destroy = true

  tags = {
    Project     = "burstlab"
    ClusterName = var.cluster_name
    Scenario    = "ephemeral-fsx"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "fsx_data" {
  bucket = aws_s3_bucket.fsx_data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "fsx_data" {
  bucket                  = aws_s3_bucket.fsx_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =============================================================================
# IAM — FSx + S3 lifecycle permissions
# =============================================================================

# Head node needs FSx + S3 permissions because FSx create runs inline on the head node
resource "aws_iam_role_policy" "head_node_fsx_lifecycle" {
  name   = "${var.cluster_name}-workloads-fsx-lifecycle"
  role   = local.head_node_role_name
  policy = aws_iam_role_policy.burst_node_fsx_lifecycle.policy
}

resource "aws_iam_role_policy" "burst_node_fsx_lifecycle" {
  name = "${var.cluster_name}-workloads-fsx-lifecycle"
  role = local.burst_node_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "FSxLifecycle"
        Effect = "Allow"
        Action = [
          "fsx:CreateFileSystem",
          "fsx:DescribeFileSystems",
          "fsx:DeleteFileSystem",
          "fsx:TagResource",
          "fsx:ListTagsForResource",
          "fsx:CreateDataRepositoryTask",
          "fsx:DescribeDataRepositoryTasks",
          "fsx:CancelDataRepositoryTask"
        ]
        Resource = "*"
      },
      {
        Sid    = "S3DataRepository"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:AbortMultipartUpload",
          "s3:GetBucketAcl",
          "s3:PutObjectAcl"
        ]
        Resource = [
          aws_s3_bucket.fsx_data.arn,
          "${aws_s3_bucket.fsx_data.arn}/*"
        ]
      },
      {
        # FSx needs to pass a service role when creating filesystems with data repos
        Sid    = "PassFSxRole"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = "arn:aws:iam::*:role/aws-service-role/s3.data-source.lustre.fsx.amazonaws.com/*"
      },
      {
        # FSx needs to create and configure the S3 data-source service-linked role per filesystem.
        # AWS FSx docs require CreateServiceLinkedRole + AttachRolePolicy + PutRolePolicy:
        # https://docs.aws.amazon.com/fsx/latest/LustreGuide/setting-up.html#fsx-adding-permissions-s3
        Sid    = "CreateFSxS3SLR"
        Effect = "Allow"
        Action = [
          "iam:CreateServiceLinkedRole",
          "iam:AttachRolePolicy",
          "iam:PutRolePolicy"
        ]
        Resource = "arn:aws:iam::*:role/aws-service-role/s3.data-source.lustre.fsx.amazonaws.com/*"
      }
    ]
  })
}

# =============================================================================
# FSx SERVICE-LINKED ROLE
# =============================================================================
# FSx requires this service-linked role to exist before creating filesystems
# with S3 data repository associations. It is account-scoped (created once,
# not per-cluster). The ignore_changes guard prevents errors if it already exists.

resource "aws_iam_service_linked_role" "fsx" {
  aws_service_name = "fsx.amazonaws.com"
  description      = "Service-linked role for Amazon FSx"

  # If the role already exists, Terraform will get a conflict error.
  # Set create_fsx_slr = false in tfvars if the role already exists in your account.
  count = var.create_fsx_service_linked_role ? 1 : 0

  lifecycle {
    ignore_changes = all
  }
}

# FSx S3 data repository service-linked role — required for FSx Lustre filesystems
# that use an S3 data repository association (AutoImportPolicy / data repo tasks).
# This is a DIFFERENT role from AWSServiceRoleForAmazonFSx above.
resource "aws_iam_service_linked_role" "fsx_s3" {
  aws_service_name = "s3.data-source.lustre.fsx.amazonaws.com"
  description      = "Service-linked role for FSx Lustre S3 data repositories"

  count = var.create_fsx_s3_service_linked_role ? 1 : 0

  lifecycle {
    ignore_changes = all
  }
}
