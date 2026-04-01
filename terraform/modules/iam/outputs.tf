# =============================================================================
# IAM MODULE OUTPUTS
# =============================================================================

output "head_node_instance_profile_arn" {
  description = "ARN of the head node EC2 instance profile. Attached to the head node EC2 instance so slurmctld and aws-plugin-for-slurm can call EC2/IAM APIs."
  value       = aws_iam_instance_profile.head_node.arn
}

output "head_node_instance_profile_name" {
  description = "Name of the head node instance profile. Used when attaching the profile to the EC2 instance resource."
  value       = aws_iam_instance_profile.head_node.name
}

output "burst_node_instance_profile_arn" {
  description = "ARN of the burst node EC2 instance profile. Referenced in the burst launch template so new burst nodes start with the correct role."
  value       = aws_iam_instance_profile.burst_node.arn
}

output "burst_node_instance_profile_name" {
  description = "Name of the burst node instance profile. Passed to the burst-config module for use in the launch template."
  value       = aws_iam_instance_profile.burst_node.name
}

output "burst_node_role_arn" {
  description = "ARN of the burst node IAM role. Exposed for debugging and for the head node PassRole policy reference."
  value       = aws_iam_role.burst_node.arn
}

output "head_node_role_arn" {
  description = "ARN of the head node IAM role. Exposed for debugging and audit purposes."
  value       = aws_iam_role.head_node.arn
}

output "head_node_role_name" {
  description = "Name of the head node IAM role. Used to attach inline policies (e.g., S3 read for cluster scripts)."
  value       = aws_iam_role.head_node.name
}
