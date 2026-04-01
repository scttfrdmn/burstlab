# =============================================================================
# LOCALS — BurstLab Gen 3
# Rocky Linux 10 + Slurm 24.05.x
# =============================================================================

locals {
  effective_compute_ami = var.compute_node_ami != "" ? var.compute_node_ami : var.head_node_ami
  head_node_private_ip  = var.head_node_static_ip

  # Config templates for Gen 3 (Rocky 10 + Slurm 24.05)
  config_dir  = "${path.module}/../../../configs/gen3-slurm2405-rocky10"
  scripts_dir = "${path.module}/../../../scripts"

  slurm_conf = templatefile("${local.config_dir}/slurm.conf.tpl", {
    cluster_name       = var.cluster_name
    head_node_ip       = local.head_node_private_ip
    compute_node_count = var.compute_node_count
    slurm_prefix       = "/opt/slurm"
    burst_node_conf    = ""
  })

  slurmdbd_conf = templatefile("${local.config_dir}/slurmdbd.conf.tpl", {
    cluster_name         = var.cluster_name
    slurmdbd_db_password = random_password.slurmdbd_db.result
    slurm_prefix         = "/opt/slurm"
  })

  cgroup_conf = file("${local.config_dir}/cgroup.conf")

  plugin_config_json = templatefile("${local.config_dir}/plugin_config.json.tpl", {
    aws_region         = var.aws_region
    cluster_name       = var.cluster_name
    launch_template_id = module.burst_config.launch_template_id
    cloud_subnet_a_id  = module.vpc.cloud_subnet_a_id
    cloud_subnet_b_id  = module.vpc.cloud_subnet_b_id
    max_burst_nodes    = var.max_burst_nodes
    slurm_prefix       = "/opt/slurm"
  })

  partitions_json = templatefile("${local.config_dir}/partitions.json.tpl", {
    launch_template_id  = module.burst_config.launch_template_id
    cloud_subnet_a_id   = module.vpc.cloud_subnet_a_id
    cloud_subnet_b_id   = module.vpc.cloud_subnet_b_id
    max_burst_nodes     = var.max_burst_nodes
    burst_instance_type = var.burst_node_instance_type
    aws_region          = var.aws_region
    cluster_name        = var.cluster_name
  })

}
