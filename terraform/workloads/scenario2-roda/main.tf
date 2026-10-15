# =============================================================================
# SCENARIO 2 — RODA (Registry of Open Data on AWS)
# =============================================================================
# Enables burst nodes to read from public RODA datasets and write results to
# a customer S3 bucket. No data staging job required — data is already in AWS.
#
# Prerequisites: base/ layer must be deployed first.
#
# What this layer does:
#   1. Creates a results S3 bucket for job output
#   2. Grants burst nodes read access to the specified RODA S3 bucket
#   3. Grants burst nodes write access to the results bucket

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.0" }
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

  burst_node_role_name = element(split("/", data.terraform_remote_state.cluster.outputs.burst_node_role_arn), 1)
}

# Results bucket for job output
resource "aws_s3_bucket" "results" {
  bucket_prefix = "${local.cluster_name}-roda-results-"
  force_destroy = true

  tags = {
    Project     = "burstlab"
    ClusterName = local.cluster_name
    Scenario    = "roda"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket                  = aws_s3_bucket.results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Grant burst nodes read access to the RODA dataset bucket
resource "aws_iam_role_policy" "burst_node_roda_read" {
  name = "${local.cluster_name}-workloads-roda-read"
  role = local.burst_node_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RODARead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.roda_bucket}",
          "arn:aws:s3:::${var.roda_bucket}/*"
        ]
      },
      {
        Sid    = "ResultsWrite"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource = [
          aws_s3_bucket.results.arn,
          "${aws_s3_bucket.results.arn}/*"
        ]
      }
    ]
  })
}
