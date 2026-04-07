# =============================================================================
# SCENARIO 3 — Wrapper approach (efs-sbatch)
# =============================================================================
# Deploys the efs-sbatch wrapper to /opt/slurm/bin/ on the head node.
# Jobs that contain #SBATCH --comment=efs trigger automatic EFS lifecycle.
#
# Prerequisites: scenario3-ephemeral-efs/ must be applied first.
#
# After applying, submit jobs via:
#   efs-sbatch /opt/slurm/etc/workloads/jobs/scenario3/wrapper/example-job.sh
# =============================================================================

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

data "terraform_remote_state" "scenario3" {
  backend = "local"
  config  = { path = "${path.module}/../scenario3-ephemeral-efs/terraform.tfstate" }
}

locals {
  head_node_ip      = data.terraform_remote_state.cluster.outputs.head_node_public_ip
  burst_subnet_id   = data.terraform_remote_state.scenario3.outputs.burst_subnet_id
  # Also get cloud_subnet_a_id for EFS — burst nodes can land in either AZ,
  # and EFS DNS is AZ-specific (only resolves if a mount target exists in the
  # same AZ). Creating mount targets in both subnets ensures reliable DNS.
  cloud_subnet_a_id = data.terraform_remote_state.cluster.outputs.cloud_subnet_a_id
  efs_sg_id         = data.terraform_remote_state.scenario3.outputs.efs_sg_id
  scripts_dir       = "${path.module}/../../../scripts/workloads"
}

# Write /etc/sysconfig/burstlab-workloads (EFS-specific fields)
# Note: if scenario4-wrapper/ is also applied, this will update the same file
# to include both FSx and EFS variables.
resource "null_resource" "write_sysconfig" {
  triggers = {
    head_node_ip      = local.head_node_ip
    burst_subnet_id   = local.burst_subnet_id
    cloud_subnet_a_id = local.cloud_subnet_a_id
    efs_sg_id         = local.efs_sg_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -i ${var.key_path} -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
        rocky@${local.head_node_ip} << 'ENDSSH'
        # Idempotently add EFS vars to sysconfig (preserve existing FSx vars)
        sudo touch /etc/sysconfig/burstlab-workloads
        grep -q '^AWS_REGION=' /etc/sysconfig/burstlab-workloads || \
          echo "AWS_REGION=${var.aws_region}" | sudo tee -a /etc/sysconfig/burstlab-workloads > /dev/null
        grep -q '^BURST_SUBNET_ID=' /etc/sysconfig/burstlab-workloads || \
          echo "BURST_SUBNET_ID=${local.burst_subnet_id}" | sudo tee -a /etc/sysconfig/burstlab-workloads > /dev/null
        grep -q '^EFS_SG_ID=' /etc/sysconfig/burstlab-workloads || \
          echo "EFS_SG_ID=${local.efs_sg_id}" | sudo tee -a /etc/sysconfig/burstlab-workloads > /dev/null
        # CLOUD_SUBNET_A_ID: needed for EFS second mount target in us-west-2a.
        # EFS DNS is AZ-specific — burst nodes in cloud_a won't resolve EFS
        # DNS unless a mount target also exists in cloud_a.
        grep -q '^CLOUD_SUBNET_A_ID=' /etc/sysconfig/burstlab-workloads || \
          echo "CLOUD_SUBNET_A_ID=${local.cloud_subnet_a_id}" | sudo tee -a /etc/sysconfig/burstlab-workloads > /dev/null
        sudo chmod 644 /etc/sysconfig/burstlab-workloads
ENDSSH
    EOT
  }
}

# Deploy efs-sbatch + efs-cleanup to /opt/slurm/bin/
resource "null_resource" "deploy_efs_commands" {
  depends_on = [null_resource.write_sysconfig]

  triggers = {
    head_node_ip  = local.head_node_ip
    wrapper_hash  = filemd5("${local.scripts_dir}/jobs/scenario3/wrapper/efs-sbatch")
    cleanup_hash  = filemd5("${local.scripts_dir}/jobs/scenario3/efs-cleanup")
    example_hash  = filemd5("${local.scripts_dir}/jobs/scenario3/wrapper/example-job.sh")
  }

  provisioner "local-exec" {
    command = <<-EOT
      SSH="ssh -i ${var.key_path} -o StrictHostKeyChecking=no -o ConnectTimeout=15"
      SCP="scp -i ${var.key_path} -o StrictHostKeyChecking=no"

      $SCP \
        ${local.scripts_dir}/jobs/scenario3/wrapper/efs-sbatch \
        ${local.scripts_dir}/jobs/scenario3/efs-cleanup \
        ${local.scripts_dir}/jobs/scenario3/wrapper/example-job.sh \
        rocky@${local.head_node_ip}:/tmp/

      $SSH rocky@${local.head_node_ip} "
        sudo install -o root -g root -m 0755 /tmp/efs-sbatch  /opt/slurm/bin/efs-sbatch
        sudo install -o root -g root -m 0755 /tmp/efs-cleanup /opt/slurm/bin/efs-cleanup
        sudo mkdir -p /opt/slurm/etc/workloads/jobs/scenario3/wrapper
        sudo install -o root -g root -m 0755 /tmp/example-job.sh \
          /opt/slurm/etc/workloads/jobs/scenario3/wrapper/example-job.sh
      "
    EOT
  }
}
