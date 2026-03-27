# =============================================================================
# VPC MODULE OUTPUTS
# =============================================================================
# These outputs are consumed by multiple other modules. Keep them stable —
# changing an output name requires updating every module that references it.

output "vpc_id" {
  description = "ID of the BurstLab VPC. Passed to almost every other module for resource scoping."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC (10.0.0.0/16). Used in security group rules to allow all intra-VPC traffic."
  value       = aws_vpc.main.cidr_block
}

# -----------------------------------------------------------------------------
# Subnet IDs
# -----------------------------------------------------------------------------

output "management_subnet_id" {
  description = "Subnet ID for the management subnet (head node). The head-node module places the EC2 instance here."
  value       = aws_subnet.management.id
}

output "management_subnet_cidr" {
  description = "CIDR of the management subnet. Used when constructing Slurm node address ranges."
  value       = aws_subnet.management.cidr_block
}

output "onprem_subnet_id" {
  description = "Subnet ID for the on-prem compute subnet (compute01-04). The compute-nodes module places instances here."
  value       = aws_subnet.onprem.id
}

output "onprem_subnet_cidr" {
  description = "CIDR of the on-prem compute subnet. Referenced in slurm.conf NodeAddr ranges."
  value       = aws_subnet.onprem.cidr_block
}

output "cloud_subnet_a_id" {
  description = "Subnet ID for cloud burst subnet A (us-west-2a). Referenced in the burst launch template and partitions.json."
  value       = aws_subnet.cloud_a.id
}

output "cloud_subnet_a_cidr" {
  description = "CIDR of cloud burst subnet A."
  value       = aws_subnet.cloud_a.cidr_block
}

output "cloud_subnet_b_id" {
  description = "Subnet ID for cloud burst subnet B (us-west-2b). Second AZ improves burst capacity availability."
  value       = aws_subnet.cloud_b.id
}

output "cloud_subnet_b_cidr" {
  description = "CIDR of cloud burst subnet B."
  value       = aws_subnet.cloud_b.cidr_block
}

# -----------------------------------------------------------------------------
# Route Table IDs — consumed by head-node module to add NAT routes
# -----------------------------------------------------------------------------
# The head-node module must add aws_route resources pointing 0.0.0.0/0 at the
# head node's ENI. To do that it needs these route table IDs.

output "onprem_route_table_id" {
  description = "Route table ID for the on-prem compute subnet. Head-node module adds 0.0.0.0/0 → head-node ENI here (NAT routing for compute nodes)."
  value       = aws_route_table.onprem.id
}

output "cloud_route_table_id" {
  description = "Route table ID for both cloud burst subnets (shared). Head-node module adds 0.0.0.0/0 → head-node ENI here (NAT routing for burst nodes)."
  value       = aws_route_table.cloud.id
}

# -----------------------------------------------------------------------------
# Security Group IDs
# -----------------------------------------------------------------------------

output "head_node_sg_id" {
  description = "Security group ID for the head node. Allows SSH from internet + all VPC traffic."
  value       = aws_security_group.head_node.id
}

output "compute_node_sg_id" {
  description = "Security group ID for on-prem compute nodes. All intra-VPC traffic only."
  value       = aws_security_group.compute_node.id
}

output "burst_node_sg_id" {
  description = "Security group ID for cloud burst nodes. All intra-VPC traffic only."
  value       = aws_security_group.burst_node.id
}

output "efs_sg_id" {
  description = "Security group ID for EFS mount targets. Accepts NFS (TCP 2049) from VPC CIDR."
  value       = aws_security_group.efs.id
}
