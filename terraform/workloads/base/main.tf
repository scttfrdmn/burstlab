# =============================================================================
# BASE WORKLOADS LAYER — BurstLab
# =============================================================================
# Deploy this layer once per cluster before any scenario overlays.
#
# What this layer does:
#   1. Reads the deployed generation cluster's Terraform outputs via remote state
#   2. Creates an S3 bucket for workload scripts
#   3. Grants the head node IAM role read access to the workloads bucket
#   4. Deploys all workload scripts to /opt/slurm/etc/workloads/ on the head node
#   5. Installs transfer tools (rclone, s5cmd, AWS Mountpoint) on the head node
#
# Prerequisites:
#   - A generation cluster must be deployed and healthy
#   - SSH key must be accessible at var.key_path
#   - Head node must be reachable on its public IP
#
# Usage:
#   cp terraform.tfvars.example terraform.tfvars   # fill in gen_state_path, key_path
#   terraform init
#   terraform apply

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# =============================================================================
# READ CLUSTER STATE
# =============================================================================
# Reads outputs from the deployed generation cluster's local state file.
# The generation root modules all use the implicit local backend.

data "terraform_remote_state" "cluster" {
  backend = "local"
  config = {
    path = var.gen_state_path
  }
}

locals {
  head_node_ip         = data.terraform_remote_state.cluster.outputs.head_node_public_ip
  head_node_priv_ip    = data.terraform_remote_state.cluster.outputs.head_node_private_ip
  vpc_id               = data.terraform_remote_state.cluster.outputs.vpc_id
  cloud_subnet_a_id    = data.terraform_remote_state.cluster.outputs.cloud_subnet_a_id
  cloud_subnet_b_id    = data.terraform_remote_state.cluster.outputs.cloud_subnet_b_id
  efs_id               = data.terraform_remote_state.cluster.outputs.efs_id
  efs_dns_name         = data.terraform_remote_state.cluster.outputs.efs_dns_name
  head_node_role_arn   = data.terraform_remote_state.cluster.outputs.head_node_role_arn
  burst_node_role_arn  = data.terraform_remote_state.cluster.outputs.burst_node_role_arn

  # Derive role names from ARNs — avoids requiring new outputs from core modules.
  # ARN format: arn:aws:iam::ACCOUNT:role/NAME
  head_node_role_name  = element(split("/", local.head_node_role_arn), 1)
  burst_node_role_name = element(split("/", local.burst_node_role_arn), 1)

  # Path to the workloads scripts directory, relative to this module
  scripts_dir = "${path.module}/../../../scripts/workloads"
}

# =============================================================================
# S3 BUCKET — workload scripts repository
# =============================================================================
# Stores installer scripts and job scripts. The head node syncs from here.
# force_destroy=true makes terraform destroy clean without manual emptying.

resource "aws_s3_bucket" "workloads" {
  bucket_prefix = "${var.cluster_name}-workloads-"
  force_destroy = true

  tags = {
    Project     = "burstlab"
    ClusterName = var.cluster_name
    Layer       = "workloads-base"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "workloads" {
  bucket = aws_s3_bucket.workloads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "workloads" {
  bucket                  = aws_s3_bucket.workloads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# =============================================================================
# IAM — grant head node access to workloads bucket
# =============================================================================
# Inline policy attached to the existing head node role.
# Inline policies are scenario-scoped and removed cleanly with terraform destroy.

resource "aws_iam_role_policy" "head_node_workloads_s3" {
  name = "${var.cluster_name}-workloads-s3"
  role = local.head_node_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject"
      ]
      Resource = [
        aws_s3_bucket.workloads.arn,
        "${aws_s3_bucket.workloads.arn}/*"
      ]
    }]
  })
}

# =============================================================================
# SCRIPT DEPLOYMENT — rsync workload scripts to head node
# =============================================================================
# Triggers re-deploy if any script in scripts/workloads/ changes.
# Uses rsync (always available on macOS and Linux) for efficiency.
# Scripts land at /opt/slurm/etc/workloads/ on EFS — shared with all nodes.

resource "null_resource" "deploy_workload_scripts" {
  triggers = {
    head_node_ip = local.head_node_ip
    scripts_hash = sha256(join("|", [
      for f in fileset("${local.scripts_dir}", "**/*.sh") :
      filesha256("${local.scripts_dir}/${f}")
    ]))
  }

  provisioner "local-exec" {
    command = <<-EOT
      SSH_OPTS="-i ${var.key_path} -o StrictHostKeyChecking=no -o ConnectTimeout=15"

      echo "=== BurstLab Workloads: deploying scripts ==="

      # Wait for SSH (head node may still be initializing)
      for attempt in $(seq 1 20); do
        ssh $SSH_OPTS rocky@${local.head_node_ip} "echo ok" >/dev/null 2>&1 && break
        echo "  SSH attempt $attempt/20 — waiting 15s..."
        sleep 15
      done
      ssh $SSH_OPTS rocky@${local.head_node_ip} "echo ok" >/dev/null 2>&1 \
        || { echo "ERROR: SSH never became available on ${local.head_node_ip}"; exit 1; }

      # Create directory structure on EFS
      ssh $SSH_OPTS rocky@${local.head_node_ip} \
        "sudo mkdir -p /opt/slurm/etc/workloads/lib /opt/slurm/etc/workloads/jobs/scenario{1,2,3,4} /opt/slurm/etc/workloads/data"

      # rsync scripts (preserves directory structure, skips unchanged files)
      rsync -avz --delete \
        -e "ssh $SSH_OPTS" \
        ${local.scripts_dir}/ \
        rocky@${local.head_node_ip}:/tmp/burstlab-workloads/

      # Move from /tmp to EFS location and set permissions
      ssh $SSH_OPTS rocky@${local.head_node_ip} "
        sudo cp -r /tmp/burstlab-workloads/. /opt/slurm/etc/workloads/
        sudo find /opt/slurm/etc/workloads -name '*.sh' -exec chmod 755 {} +
        echo 'Scripts deployed to /opt/slurm/etc/workloads/'
        ls /opt/slurm/etc/workloads/
      "
      echo "=== Script deployment complete ==="
    EOT
  }

  depends_on = [aws_iam_role_policy.head_node_workloads_s3]
}

# =============================================================================
# INSTALL TRANSFER TOOLS — rclone, s5cmd, AWS Mountpoint
# =============================================================================

resource "null_resource" "install_transfer_tools" {
  triggers = {
    head_node_ip = local.head_node_ip
    script_hash  = filesha256("${local.scripts_dir}/install-transfer-tools.sh")
  }

  provisioner "local-exec" {
    command = <<-EOT
      SSH_OPTS="-i ${var.key_path} -o StrictHostKeyChecking=no"
      echo "=== BurstLab Workloads: installing transfer tools ==="
      ssh $SSH_OPTS rocky@${local.head_node_ip} \
        "sudo bash /opt/slurm/etc/workloads/install-transfer-tools.sh ${var.aws_region}" \
        && echo "=== Transfer tools installed ==="
    EOT
  }

  depends_on = [null_resource.deploy_workload_scripts]
}
