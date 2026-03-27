# =============================================================================
# BURST CONFIG MODULE OUTPUTS
# =============================================================================

output "launch_template_id" {
  description = "ID of the burst node EC2 launch template. This ID is written into partitions.json (LaunchTemplateId field) so aws-plugin-for-slurm knows which template to use when calling EC2 Fleet."
  value       = aws_launch_template.burst.id
}

output "launch_template_name" {
  description = "Name of the burst node launch template. Useful for debugging and for referencing in the AWS console."
  value       = aws_launch_template.burst.name
}

output "launch_template_latest_version" {
  description = "Latest version number of the launch template. The plugin should reference '$Latest' in partitions.json to always use the most recent version."
  value       = aws_launch_template.burst.latest_version
}
