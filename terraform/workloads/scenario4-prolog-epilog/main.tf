# =============================================================================
# SCENARIO 4 — Prolog/Epilog approach (SlurmctldProlog + SlurmctldEpilog)
# =============================================================================
# Deploys FSx lifecycle prolog/epilog scripts and patches slurm.conf to
# reference them. The SlurmctldProlog creates FSx when a job has
# #SBATCH --comment=fsx:N, injects FSX_STATE_FILE into the job environment,
# and the SlurmctldEpilog flushes and destroys after the job completes.
#
# Prerequisites:
#   scenario4-ephemeral-fsx/ must be applied first (S3 bucket, IAM, SLRs).
#
# If scenario3-prolog-epilog/ is ALSO applied, both modules write to the
# SAME combined storage-slurmctld-prolog.sh dispatcher. Apply them in order:
#   scenario4-prolog-epilog first, then scenario3-prolog-epilog.
#
# After applying, the SA submits jobs via standard sbatch:
#   sbatch --partition=aws \
#     /opt/slurm/etc/workloads/jobs/scenario4/prolog-epilog/example-job.sh
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
  head_node_ip      = data.terraform_remote_state.cluster.outputs.head_node_public_ip
  s3_data_bucket    = data.terraform_remote_state.scenario4.outputs.s3_data_bucket
  s3_results_bucket = data.terraform_remote_state.scenario4.outputs.s3_results_bucket
  burst_subnet_id   = data.terraform_remote_state.scenario4.outputs.burst_subnet_id
  fsx_sg_id         = data.terraform_remote_state.scenario4.outputs.fsx_sg_id
  scripts_dir       = "${path.module}/../../../scripts/workloads"
}

# Write /etc/sysconfig/burstlab-workloads (shared with wrapper module)
resource "null_resource" "write_sysconfig" {
  triggers = {
    head_node_ip      = local.head_node_ip
    s3_data_bucket    = local.s3_data_bucket
    s3_results_bucket = local.s3_results_bucket
    burst_subnet_id   = local.burst_subnet_id
    fsx_sg_id         = local.fsx_sg_id
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
        grep -q '^RESULTS_BUCKET=' /etc/sysconfig/burstlab-workloads || \
          echo "RESULTS_BUCKET=${local.s3_results_bucket}" | sudo tee -a /etc/sysconfig/burstlab-workloads > /dev/null
        sudo chmod 644 /etc/sysconfig/burstlab-workloads
ENDSSH
    EOT
  }
}

# Deploy FSx prolog/epilog scripts to /opt/slurm/etc/scripts/
resource "null_resource" "deploy_prolog_epilog" {
  depends_on = [null_resource.write_sysconfig]

  triggers = {
    head_node_ip  = local.head_node_ip
    prolog_hash   = filemd5("${local.scripts_dir}/jobs/scenario4/prolog-epilog/fsx-slurmctld-prolog.sh")
    epilog_hash   = filemd5("${local.scripts_dir}/jobs/scenario4/prolog-epilog/fsx-slurmctld-epilog.sh")
    example_hash  = filemd5("${local.scripts_dir}/jobs/scenario4/prolog-epilog/example-job.sh")
    combined_prolog_hash = filemd5("${local.scripts_dir}/storage-slurmctld-prolog.sh")
    combined_epilog_hash = filemd5("${local.scripts_dir}/storage-slurmctld-epilog.sh")
  }

  provisioner "local-exec" {
    command = <<-EOT
      SSH="ssh -i ${var.key_path} -o StrictHostKeyChecking=no -o ConnectTimeout=15"
      SCP="scp -i ${var.key_path} -o StrictHostKeyChecking=no"

      # Upload scripts to /tmp first, then move to EFS with sudo
      $SCP \
        ${local.scripts_dir}/jobs/scenario4/prolog-epilog/fsx-slurmctld-prolog.sh \
        ${local.scripts_dir}/jobs/scenario4/prolog-epilog/fsx-slurmctld-epilog.sh \
        ${local.scripts_dir}/jobs/scenario4/prolog-epilog/example-job.sh \
        ${local.scripts_dir}/storage-slurmctld-prolog.sh \
        ${local.scripts_dir}/storage-slurmctld-epilog.sh \
        rocky@${local.head_node_ip}:/tmp/

      $SSH rocky@${local.head_node_ip} "
        sudo mkdir -p /opt/slurm/etc/scripts
        sudo install -o root -g root -m 0755 \
          /tmp/fsx-slurmctld-prolog.sh \
          /opt/slurm/etc/scripts/fsx-slurmctld-prolog.sh
        sudo install -o root -g root -m 0755 \
          /tmp/fsx-slurmctld-epilog.sh \
          /opt/slurm/etc/scripts/fsx-slurmctld-epilog.sh
        sudo install -o root -g root -m 0755 \
          /tmp/storage-slurmctld-prolog.sh \
          /opt/slurm/etc/scripts/storage-slurmctld-prolog.sh
        sudo install -o root -g root -m 0755 \
          /tmp/storage-slurmctld-epilog.sh \
          /opt/slurm/etc/scripts/storage-slurmctld-epilog.sh
        sudo mkdir -p /opt/slurm/etc/workloads/jobs/scenario4/prolog-epilog
        sudo install -o root -g root -m 0755 \
          /tmp/example-job.sh \
          /opt/slurm/etc/workloads/jobs/scenario4/prolog-epilog/example-job.sh
      "
    EOT
  }
}

# Patch slurm.conf to add SlurmctldProlog, SlurmctldEpilog, PrologEpilogTimeout
# Idempotent: grep before appending. scontrol reconfigure applies without restart.
resource "null_resource" "patch_slurm_conf" {
  depends_on = [null_resource.deploy_prolog_epilog]

  triggers = {
    head_node_ip = local.head_node_ip
    prolog_path  = "/opt/slurm/etc/scripts/storage-slurmctld-prolog.sh"
    epilog_path  = "/opt/slurm/etc/scripts/storage-slurmctld-epilog.sh"
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -i ${var.key_path} -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
        rocky@${local.head_node_ip} << 'ENDSSH'
        CONF=/opt/slurm/etc/slurm.conf

        # Append SlurmctldProlog if not already present
        grep -q '^SlurmctldProlog=' "$CONF" || \
          echo 'SlurmctldProlog=/opt/slurm/etc/scripts/storage-slurmctld-prolog.sh' \
            | sudo tee -a "$CONF" > /dev/null

        # Append SlurmctldEpilog if not already present
        grep -q '^SlurmctldEpilog=' "$CONF" || \
          echo 'SlurmctldEpilog=/opt/slurm/etc/scripts/storage-slurmctld-epilog.sh' \
            | sudo tee -a "$CONF" > /dev/null

        # Append PrologEpilogTimeout if not already present
        grep -q '^PrologEpilogTimeout=' "$CONF" || \
          echo 'PrologEpilogTimeout=1800' \
            | sudo tee -a "$CONF" > /dev/null

        # Reload slurmctld without restart
        /opt/slurm/bin/scontrol reconfigure
        echo "slurm.conf patched and scontrol reconfigure done"
ENDSSH
    EOT
  }
}
