# =============================================================================
# SCENARIO 1 — Compute-only (Spack + Lmod + GROMACS on shared EFS)
# =============================================================================
# Installs Spack, Lmod, and GROMACS onto the cluster's shared EFS so all nodes
# (head, compute, burst) can run GROMACS jobs without staging any input data.
#
# Prerequisites: base/ layer must be deployed first.
#
# What this layer does:
#   1. Bootstraps Spack + Lmod to /opt/slurm/spack/ on EFS
#   2. Installs GROMACS via the AWS Spack binary cache (no source build)
#   3. Creates sample input data for demo jobs
#
# Estimated apply time: 10-20 minutes (Spack + GROMACS from binary cache)

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.0" }
    null = { source = "hashicorp/null", version = "~> 3.0" }
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

  head_node_ip = data.terraform_remote_state.cluster.outputs.head_node_public_ip
  scripts_dir  = "${path.module}/../../../scripts/workloads"
}

# Install Spack + Lmod to /opt/slurm/spack/ on EFS
resource "null_resource" "install_spack" {
  triggers = {
    head_node_ip = local.head_node_ip
    script_hash  = filesha256("${local.scripts_dir}/install-spack.sh")
  }

  provisioner "local-exec" {
    command = <<-EOT
      SSH_OPTS="-i ${var.key_path} -o StrictHostKeyChecking=no"
      echo "=== Installing Spack + Lmod (this takes 10-15 minutes) ==="
      ssh $SSH_OPTS ${local.ssh_user}@${local.head_node_ip} \
        "sudo bash /opt/slurm/etc/workloads/install-spack.sh" \
        && echo "=== Spack installed ==="
    EOT
  }
}

# Install GROMACS via Spack binary cache (separate from base Spack install)
resource "null_resource" "install_gromacs" {
  triggers = {
    head_node_ip = local.head_node_ip
    script_hash  = filesha256("${local.scripts_dir}/install-gromacs.sh")
  }

  provisioner "local-exec" {
    command = <<-EOT
      SSH_OPTS="-i ${var.key_path} -o StrictHostKeyChecking=no"
      echo "=== Installing GROMACS via Spack binary cache ==="
      ssh $SSH_OPTS ${local.ssh_user}@${local.head_node_ip} \
        "sudo bash /opt/slurm/etc/workloads/install-gromacs.sh" \
        && echo "=== GROMACS installed ==="
    EOT
  }

  depends_on = [null_resource.install_spack]
}
