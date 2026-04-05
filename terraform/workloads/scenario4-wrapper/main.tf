# =============================================================================
# SCENARIO 4 — Wrapper approach (fsx-sbatch)
# =============================================================================
# Deploys the fsx-sbatch wrapper to /opt/slurm/bin/ on the head node.
# The wrapper intercepts job submissions that contain #SBATCH --comment=fsx:N,
# creates FSx inline, injects FSX_STATE_FILE into the job environment, and
# submits the destroy job automatically.
#
# Prerequisites:
#   scenario4-ephemeral-fsx/ must be applied first (S3 bucket, IAM, SLRs).
#
# After applying, the SA submits jobs via:
#   fsx-sbatch /opt/slurm/etc/workloads/jobs/scenario4/wrapper/example-job.sh
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

data "terraform_remote_state" "scenario4" {
  backend = "local"
  config  = { path = "${path.module}/../scenario4-ephemeral-fsx/terraform.tfstate" }
}

locals {
  head_node_ip   = data.terraform_remote_state.cluster.outputs.head_node_public_ip
  s3_data_bucket = data.terraform_remote_state.scenario4.outputs.s3_data_bucket
  burst_subnet_id = data.terraform_remote_state.scenario4.outputs.burst_subnet_id
  fsx_sg_id      = data.terraform_remote_state.scenario4.outputs.fsx_sg_id
  scripts_dir    = "${path.module}/../../../scripts/workloads"
}

# Write /etc/sysconfig/burstlab-workloads on the head node so prolog/epilog and
# wrapper scripts can read cluster-specific values without requiring env vars.
resource "null_resource" "write_sysconfig" {
  triggers = {
    head_node_ip   = local.head_node_ip
    s3_data_bucket = local.s3_data_bucket
    burst_subnet_id = local.burst_subnet_id
    fsx_sg_id      = local.fsx_sg_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -i ${var.key_path} -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
        rocky@${local.head_node_ip} << 'ENDSSH'
        sudo touch /etc/sysconfig/burstlab-workloads
        grep -q '^AWS_REGION=' /etc/sysconfig/burstlab-workloads || \
          echo "AWS_REGION=${var.aws_region}" | sudo tee -a /etc/sysconfig/burstlab-workloads > /dev/null
        grep -q '^BURST_SUBNET_ID=' /etc/sysconfig/burstlab-workloads || \
          echo "BURST_SUBNET_ID=${local.burst_subnet_id}" | sudo tee -a /etc/sysconfig/burstlab-workloads > /dev/null
        grep -q '^FSX_SG_ID=' /etc/sysconfig/burstlab-workloads || \
          echo "FSX_SG_ID=${local.fsx_sg_id}" | sudo tee -a /etc/sysconfig/burstlab-workloads > /dev/null
        grep -q '^S3_DATA_BUCKET=' /etc/sysconfig/burstlab-workloads || \
          echo "S3_DATA_BUCKET=${local.s3_data_bucket}" | sudo tee -a /etc/sysconfig/burstlab-workloads > /dev/null
        sudo chmod 644 /etc/sysconfig/burstlab-workloads
ENDSSH
    EOT
  }
}

# Deploy fsx-sbatch wrapper to /opt/slurm/bin/ (in PATH ahead of real sbatch)
resource "null_resource" "deploy_fsx_sbatch" {
  depends_on = [null_resource.write_sysconfig]

  triggers = {
    head_node_ip  = local.head_node_ip
    wrapper_hash  = filemd5("${local.scripts_dir}/jobs/scenario4/wrapper/fsx-sbatch")
    example_hash  = filemd5("${local.scripts_dir}/jobs/scenario4/wrapper/example-job.sh")
  }

  provisioner "local-exec" {
    command = <<-EOT
      SSH="ssh -i ${var.key_path} -o StrictHostKeyChecking=no -o ConnectTimeout=15"
      SCP="scp -i ${var.key_path} -o StrictHostKeyChecking=no"

      $SCP ${local.scripts_dir}/jobs/scenario4/wrapper/fsx-sbatch \
        rocky@${local.head_node_ip}:/tmp/fsx-sbatch
      $SCP ${local.scripts_dir}/jobs/scenario4/wrapper/example-job.sh \
        rocky@${local.head_node_ip}:/tmp/fsx-wrapper-example-job.sh

      $SSH rocky@${local.head_node_ip} "
        sudo install -o root -g root -m 0755 /tmp/fsx-sbatch /opt/slurm/bin/fsx-sbatch
        sudo install -o root -g root -m 0755 /tmp/fsx-wrapper-example-job.sh \
          /opt/slurm/etc/workloads/jobs/scenario4/wrapper/example-job.sh
      "
    EOT
  }
}
