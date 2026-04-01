# =============================================================================
# SHARED STORAGE MODULE OUTPUTS
# =============================================================================

output "efs_id" {
  description = "EFS filesystem ID (fs-XXXXXXXX). Used in mount commands and for debugging in the AWS console."
  value       = aws_efs_file_system.main.id
}

output "efs_dns_name" {
  description = "EFS filesystem DNS name (fs-XXXXXXXX.efs.REGION.amazonaws.com). Passed to node init scripts for mount commands. Requires enable_dns_hostnames=true on the VPC."
  value       = aws_efs_file_system.main.dns_name
}

output "efs_home_access_point_id" {
  description = "Access point ID for the /u (home) export."
  value       = aws_efs_access_point.home.id
}

output "efs_slurm_access_point_id" {
  description = "Access point ID for the /opt/slurm export. Used in mount options for mounting Slurm binaries and config."
  value       = aws_efs_access_point.slurm.id
}
