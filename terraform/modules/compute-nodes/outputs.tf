# =============================================================================
# COMPUTE NODES MODULE OUTPUTS
# =============================================================================

output "instance_ids" {
  description = "List of EC2 instance IDs for all compute nodes. Useful for debugging and for looking up nodes in the AWS console."
  value       = aws_instance.compute[*].id
}

output "private_ips" {
  description = "List of private IP addresses for compute nodes (compute01, compute02, ...). These IPs map to the NodeAddr entries in slurm.conf."
  value       = aws_instance.compute[*].private_ip
}

output "node_names" {
  description = "List of Slurm node names corresponding to each compute instance (compute01, compute02, ...). The order matches instance_ids and private_ips."
  value = [
    for i in range(var.compute_node_count) :
    "${var.cluster_name}-compute${format("%02d", i + 1)}"
  ]
}
