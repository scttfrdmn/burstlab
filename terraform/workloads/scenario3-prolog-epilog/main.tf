# =============================================================================
# SCENARIO 3 — Prolog/Epilog approach (SlurmctldProlog + SlurmctldEpilog)
# =============================================================================
# Deploys EFS lifecycle prolog/epilog scripts and patches slurm.conf.
# Jobs with #SBATCH --comment=efs trigger automatic EFS create/destroy.
#
# Prerequisites: scenario3-ephemeral-efs/ must be applied first.
#
# If scenario4-prolog-epilog/ is ALSO applied, both share the combined
# storage-slurmctld-prolog.sh dispatcher. Apply scenario4-prolog-epilog
# first so the combined scripts are already deployed; this module only
# needs to add the per-type scripts alongside them.
#
# After applying:
#   sbatch --partition=aws \
#     /opt/slurm/etc/workloads/jobs/scenario3/prolog-epilog/example-job.sh
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
  head_node_ip    = data.terraform_remote_state.cluster.outputs.head_node_public_ip
  burst_subnet_id = data.terraform_remote_state.scenario3.outputs.burst_subnet_id
  efs_sg_id       = data.terraform_remote_state.scenario3.outputs.efs_sg_id
  scripts_dir     = "${path.module}/../../../scripts/workloads"
}

# Write sysconfig (idempotently, preserving existing FSx vars)
resource "null_resource" "write_sysconfig" {
  triggers = {
    head_node_ip    = local.head_node_ip
    burst_subnet_id = local.burst_subnet_id
    efs_sg_id       = local.efs_sg_id
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
        grep -q '^EFS_SG_ID=' /etc/sysconfig/burstlab-workloads || \
          echo "EFS_SG_ID=${local.efs_sg_id}" | sudo tee -a /etc/sysconfig/burstlab-workloads > /dev/null
        sudo chmod 644 /etc/sysconfig/burstlab-workloads
ENDSSH
    EOT
  }
}

# Deploy EFS prolog/epilog scripts alongside any existing FSx scripts
resource "null_resource" "deploy_prolog_epilog" {
  depends_on = [null_resource.write_sysconfig]

  triggers = {
    head_node_ip = local.head_node_ip
    prolog_hash  = filemd5("${local.scripts_dir}/jobs/scenario3/prolog-epilog/efs-slurmctld-prolog.sh")
    epilog_hash  = filemd5("${local.scripts_dir}/jobs/scenario3/prolog-epilog/efs-slurmctld-epilog.sh")
    example_hash = filemd5("${local.scripts_dir}/jobs/scenario3/prolog-epilog/example-job.sh")
    combined_prolog_hash = filemd5("${local.scripts_dir}/storage-slurmctld-prolog.sh")
    combined_epilog_hash = filemd5("${local.scripts_dir}/storage-slurmctld-epilog.sh")
  }

  provisioner "local-exec" {
    command = <<-EOT
      SSH="ssh -i ${var.key_path} -o StrictHostKeyChecking=no -o ConnectTimeout=15"
      SCP="scp -i ${var.key_path} -o StrictHostKeyChecking=no"

      $SCP \
        ${local.scripts_dir}/jobs/scenario3/prolog-epilog/efs-slurmctld-prolog.sh \
        ${local.scripts_dir}/jobs/scenario3/prolog-epilog/efs-slurmctld-epilog.sh \
        ${local.scripts_dir}/jobs/scenario3/prolog-epilog/example-job.sh \
        ${local.scripts_dir}/storage-slurmctld-prolog.sh \
        ${local.scripts_dir}/storage-slurmctld-epilog.sh \
        rocky@${local.head_node_ip}:/tmp/

      $SSH rocky@${local.head_node_ip} "
        sudo mkdir -p /opt/slurm/etc/scripts
        sudo install -o root -g root -m 0755 \
          /tmp/efs-slurmctld-prolog.sh \
          /opt/slurm/etc/scripts/efs-slurmctld-prolog.sh
        sudo install -o root -g root -m 0755 \
          /tmp/efs-slurmctld-epilog.sh \
          /opt/slurm/etc/scripts/efs-slurmctld-epilog.sh
        # Always refresh the combined dispatcher (handles both fsx: and efs)
        sudo install -o root -g root -m 0755 \
          /tmp/storage-slurmctld-prolog.sh \
          /opt/slurm/etc/scripts/storage-slurmctld-prolog.sh
        sudo install -o root -g root -m 0755 \
          /tmp/storage-slurmctld-epilog.sh \
          /opt/slurm/etc/scripts/storage-slurmctld-epilog.sh
        sudo mkdir -p /opt/slurm/etc/workloads/jobs/scenario3/prolog-epilog
        sudo install -o root -g root -m 0755 \
          /tmp/example-job.sh \
          /opt/slurm/etc/workloads/jobs/scenario3/prolog-epilog/example-job.sh
      "
    EOT
  }
}

# Patch slurm.conf (idempotent — checks before appending)
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

        grep -q '^SlurmctldProlog=' "$CONF" || \
          echo 'SlurmctldProlog=/opt/slurm/etc/scripts/storage-slurmctld-prolog.sh' \
            | sudo tee -a "$CONF" > /dev/null

        grep -q '^SlurmctldEpilog=' "$CONF" || \
          echo 'SlurmctldEpilog=/opt/slurm/etc/scripts/storage-slurmctld-epilog.sh' \
            | sudo tee -a "$CONF" > /dev/null

        grep -q '^PrologEpilogTimeout=' "$CONF" || \
          echo 'PrologEpilogTimeout=1800' \
            | sudo tee -a "$CONF" > /dev/null

        /opt/slurm/bin/scontrol reconfigure
        echo "slurm.conf patched and scontrol reconfigure done"
ENDSSH
    EOT
  }
}
