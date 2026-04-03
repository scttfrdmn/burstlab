# Pass these as environment variables when submitting job chains:
#
#   CLOUD_SUBNET_A_ID=$(terraform output -raw cloud_subnet_a_id) \
#   EFS_SG_ID=$(terraform output -raw efs_sg_id) \
#   AWS_REGION=us-west-2 \
#     bash /opt/slurm/etc/workloads/jobs/scenario3/submit-chain.sh --granularity per-job

output "cloud_subnet_a_id" {
  description = "Cloud burst subnet A — required by job1 to create the EFS mount target"
  value       = local.cloud_subnet_a_id
}

output "efs_sg_id" {
  description = "EFS security group ID — required by job1 when creating the ephemeral EFS mount target"
  value       = data.aws_security_group.efs.id
}
