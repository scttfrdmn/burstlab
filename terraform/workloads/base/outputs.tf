# =============================================================================
# BASE WORKLOADS LAYER — Outputs
# =============================================================================

output "head_node_ip" {
  description = "Public IP of the head node (from cluster state)"
  value       = local.head_node_ip
}

output "workloads_s3_bucket" {
  description = "S3 bucket name for workload scripts and artifacts"
  value       = aws_s3_bucket.workloads.bucket
}

output "workloads_s3_bucket_arn" {
  description = "ARN of the workloads S3 bucket (reference in scenario IAM policies)"
  value       = aws_s3_bucket.workloads.arn
}

output "cloud_subnet_a_id" {
  description = "Cloud burst subnet A — pass to job submit scripts as CLOUD_SUBNET_A_ID"
  value       = local.cloud_subnet_a_id
}

output "efs_id" {
  description = "Cluster EFS filesystem ID — for reference and debugging"
  value       = local.efs_id
}

output "scripts_installed_at" {
  description = "Path on head node where workload scripts are installed"
  value       = "/opt/slurm/etc/workloads"
}
