# =============================================================================
# HEAD NODE MODULE OUTPUTS
# =============================================================================

output "instance_id" {
  description = "EC2 instance ID of the head node. Used for debugging, SSM sessions, and referencing in other AWS resources."
  value       = aws_instance.head_node.id
}

output "private_ip" {
  description = "Private IP address of the head node (within the management subnet). Used in slurm.conf SlurmctldHost and as the Munge/Slurm control address for all cluster nodes."
  value       = aws_instance.head_node.private_ip
}

output "public_ip" {
  description = "Public IP address (EIP) of the head node. Use this for SSH access: ssh centos@<public_ip>"
  value       = aws_eip.head_node.public_ip
}

output "eni_id" {
  description = "Primary network interface (ENI) ID of the head node. Exposed for debugging and for verifying the NAT routes were added correctly."
  value       = aws_instance.head_node.primary_network_interface_id
}

output "eip_allocation_id" {
  description = "EIP allocation ID. Useful if you need to associate the EIP with a replacement instance manually."
  value       = aws_eip.head_node.id
}
