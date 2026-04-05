# =============================================================================
# SCENARIO 4 — Burst Buffer approach (burst_buffer/lua)
# =============================================================================
# Deploys the fsx-bb.lua Lua script and burstbuffer.conf, then patches
# slurm.conf to activate the burst_buffer/lua plugin. Users submit jobs
# with standard #BB directives and see BF (stage-in) / CG (stage-out) states
# in squeue while FSx is provisioned and destroyed automatically.
#
# Prerequisites:
#   1. scenario4-ephemeral-fsx/ must be applied first.
#   2. Slurm must be built with --with-lua:
#        ls /opt/slurm-baked/lib/slurm/burst_buffer_lua.so
#      This Terraform module verifies this prerequisite before proceeding.
#      If the plugin is absent, apply will fail with a clear error message.
#      To enable BB, rebuild Slurm with --with-lua and bake into a new AMI.
#
# After applying, submit jobs via:
#   sbatch /opt/slurm/etc/workloads/jobs/scenario4/burst-buffer/example-job.sh
#
# SA talking point: "This is the same mechanism as DataWarp on Cray XC and
# GPFS Burst Buffer on IBM Spectrum LSF — industry-standard #BB directives.
# We're implementing the lifecycle against FSx instead of on-prem hardware."
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
  head_node_ip    = data.terraform_remote_state.cluster.outputs.head_node_public_ip
  s3_data_bucket  = data.terraform_remote_state.scenario4.outputs.s3_data_bucket
  burst_subnet_id = data.terraform_remote_state.scenario4.outputs.burst_subnet_id
  fsx_sg_id       = data.terraform_remote_state.scenario4.outputs.fsx_sg_id
  scripts_dir     = "${path.module}/../../../scripts/workloads"
}

# ---------------------------------------------------------------------------
# PREREQUISITE CHECK — fail fast if burst_buffer_lua.so is not compiled in
# ---------------------------------------------------------------------------
resource "null_resource" "check_bb_lua_plugin" {
  triggers = {
    head_node_ip = local.head_node_ip
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -i ${var.key_path} -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
        rocky@${local.head_node_ip} \
        "ls /opt/slurm-baked/lib/slurm/burst_buffer_lua.so 2>/dev/null || {
          echo ''
          echo 'ERROR: burst_buffer_lua.so not found in Slurm installation.'
          echo ''
          echo 'The burst_buffer/lua plugin requires Slurm to be built with --with-lua.'
          echo 'The current BurstLab AMI does not include this plugin.'
          echo ''
          echo 'To enable burst buffer support, rebuild Slurm with:'
          echo '  ./configure --with-lua ... && make && make install'
          echo 'Then bake the result into a new AMI via the Packer build.'
          echo ''
          echo 'Alternatively, use scenario4-wrapper/ or scenario4-prolog-epilog/'
          echo 'which do not require a custom Slurm build.'
          echo ''
          exit 1
        }"
    EOT
  }
}

# Install Lua on the head node (required by burst_buffer/lua at runtime)
resource "null_resource" "install_lua" {
  depends_on = [null_resource.check_bb_lua_plugin]

  triggers = {
    head_node_ip = local.head_node_ip
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -i ${var.key_path} -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
        rocky@${local.head_node_ip} \
        "lua -v 2>/dev/null || sudo dnf install -y lua && echo 'Lua ready'"
    EOT
  }
}

# Write sysconfig
resource "null_resource" "write_sysconfig" {
  depends_on = [null_resource.install_lua]

  triggers = {
    head_node_ip    = local.head_node_ip
    s3_data_bucket  = local.s3_data_bucket
    burst_subnet_id = local.burst_subnet_id
    fsx_sg_id       = local.fsx_sg_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -i ${var.key_path} -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
        rocky@${local.head_node_ip} \
        "sudo tee /etc/sysconfig/burstlab-workloads > /dev/null << 'EOF'
AWS_REGION=${var.aws_region}
BURST_SUBNET_ID=${local.burst_subnet_id}
FSX_SG_ID=${local.fsx_sg_id}
S3_DATA_BUCKET=${local.s3_data_bucket}
EOF
sudo chmod 644 /etc/sysconfig/burstlab-workloads"
    EOT
  }
}

# Deploy fsx-bb.lua, burstbuffer.conf, and example job
resource "null_resource" "deploy_burst_buffer" {
  depends_on = [null_resource.write_sysconfig]

  triggers = {
    head_node_ip  = local.head_node_ip
    lua_hash      = filemd5("${local.scripts_dir}/jobs/scenario4/burst-buffer/fsx-bb.lua")
    conf_hash     = filemd5("${local.scripts_dir}/jobs/scenario4/burst-buffer/burstbuffer.conf")
    example_hash  = filemd5("${local.scripts_dir}/jobs/scenario4/burst-buffer/example-job.sh")
  }

  provisioner "local-exec" {
    command = <<-EOT
      SSH="ssh -i ${var.key_path} -o StrictHostKeyChecking=no -o ConnectTimeout=15"
      SCP="scp -i ${var.key_path} -o StrictHostKeyChecking=no"

      $SCP \
        ${local.scripts_dir}/jobs/scenario4/burst-buffer/fsx-bb.lua \
        ${local.scripts_dir}/jobs/scenario4/burst-buffer/burstbuffer.conf \
        ${local.scripts_dir}/jobs/scenario4/burst-buffer/example-job.sh \
        rocky@${local.head_node_ip}:/tmp/

      $SSH rocky@${local.head_node_ip} "
        sudo install -o root -g root -m 0644 /tmp/fsx-bb.lua \
          /opt/slurm/etc/fsx-bb.lua
        sudo install -o root -g root -m 0644 /tmp/burstbuffer.conf \
          /opt/slurm/etc/burstbuffer.conf
        sudo mkdir -p /opt/slurm/etc/workloads/jobs/scenario4/burst-buffer
        sudo install -o root -g root -m 0755 /tmp/example-job.sh \
          /opt/slurm/etc/workloads/jobs/scenario4/burst-buffer/example-job.sh
      "
    EOT
  }
}

# Patch slurm.conf to add BurstBufferType and reload
resource "null_resource" "patch_slurm_conf" {
  depends_on = [null_resource.deploy_burst_buffer]

  triggers = {
    head_node_ip = local.head_node_ip
    lua_hash     = filemd5("${local.scripts_dir}/jobs/scenario4/burst-buffer/fsx-bb.lua")
    conf_hash    = filemd5("${local.scripts_dir}/jobs/scenario4/burst-buffer/burstbuffer.conf")
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -i ${var.key_path} -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
        rocky@${local.head_node_ip} << 'ENDSSH'
        CONF=/opt/slurm/etc/slurm.conf

        # Add BurstBufferType if not present
        grep -q '^BurstBufferType=' "$CONF" || \
          echo 'BurstBufferType=burst_buffer/lua' \
            | sudo tee -a "$CONF" > /dev/null

        # Add path to the Lua script (BBLuaScriptFile was added in Slurm 21.08)
        grep -q '^BBLuaScriptFile=' "$CONF" || \
          echo 'BBLuaScriptFile=/opt/slurm/etc/fsx-bb.lua' \
            | sudo tee -a "$CONF" > /dev/null

        /opt/slurm/bin/scontrol reconfigure
        echo "slurm.conf patched with BurstBufferType, scontrol reconfigure done"
ENDSSH
    EOT
  }
}
