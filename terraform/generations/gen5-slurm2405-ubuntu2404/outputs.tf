# =============================================================================
# ROOT MODULE OUTPUTS — BurstLab Gen 3
# Generation: gen3-slurm2405-rocky10
# =============================================================================
# These outputs are printed after `terraform apply` and accessible via
# `terraform output`. They provide the essential connection and reference
# information needed to use the cluster.

# -----------------------------------------------------------------------------
# Connection information
# -----------------------------------------------------------------------------

output "head_node_public_ip" {
  description = "Public IP (EIP) of the head node. SSH with: ssh -i ~/.ssh/<key>.pem rocky@<this_ip>"
  value       = module.head_node.public_ip
}

output "head_node_private_ip" {
  description = "Private IP of the head node within the VPC. This is the SlurmctldHost address used by all cluster nodes."
  value       = module.head_node.private_ip
}

output "head_node_instance_id" {
  description = "EC2 instance ID of the head node. Use for SSM: aws ssm start-session --target <instance_id>"
  value       = module.head_node.instance_id
}

# -----------------------------------------------------------------------------
# Compute node information
# -----------------------------------------------------------------------------

output "compute_node_instance_ids" {
  description = "List of EC2 instance IDs for on-prem compute nodes (compute01..N)."
  value       = module.compute_nodes.instance_ids
}

output "compute_node_private_ips" {
  description = "Private IPs of compute nodes. These map to NodeAddr entries in slurm.conf."
  value       = module.compute_nodes.private_ips
}

# -----------------------------------------------------------------------------
# EFS
# -----------------------------------------------------------------------------

output "efs_id" {
  description = "EFS filesystem ID."
  value       = module.shared_storage.efs_id
}

output "efs_dns_name" {
  description = "EFS DNS name. All nodes mount EFS using this address."
  value       = module.shared_storage.efs_dns_name
}

# -----------------------------------------------------------------------------
# Burst configuration
# -----------------------------------------------------------------------------

output "burst_launch_template_id" {
  description = "EC2 launch template ID for burst nodes. Written into partitions.json."
  value       = module.burst_config.launch_template_id
}

# -----------------------------------------------------------------------------
# VPC / Network
# -----------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID for the BurstLab Gen 3 cluster."
  value       = module.vpc.vpc_id
}

output "management_subnet_id" {
  description = "Subnet ID of the management subnet (head node)."
  value       = module.vpc.management_subnet_id
}

output "onprem_subnet_id" {
  description = "Subnet ID of the on-prem compute subnet."
  value       = module.vpc.onprem_subnet_id
}

output "cloud_subnet_a_id" {
  description = "Subnet ID of cloud burst subnet A (us-west-2a)."
  value       = module.vpc.cloud_subnet_a_id
}

output "cloud_subnet_b_id" {
  description = "Subnet ID of cloud burst subnet B (us-west-2b)."
  value       = module.vpc.cloud_subnet_b_id
}

# -----------------------------------------------------------------------------
# IAM
# -----------------------------------------------------------------------------

output "head_node_role_arn" {
  description = "ARN of the head node IAM role."
  value       = module.iam.head_node_role_arn
}

output "burst_node_role_arn" {
  description = "ARN of the burst node IAM role."
  value       = module.iam.burst_node_role_arn
}

# -----------------------------------------------------------------------------
# Secrets (sensitive)
# -----------------------------------------------------------------------------

output "munge_key_b64" {
  description = "Base64-encoded Munge key. All nodes share this key."
  value       = random_bytes.munge_key.base64
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Quick-start SSH command
# -----------------------------------------------------------------------------

output "ssh_command" {
  description = "Ready-to-use SSH command for connecting to the head node."
  value       = "ssh -i ~/.ssh/${var.key_name}.pem rocky@${module.head_node.public_ip}"
}
