# Pass these as environment variables when submitting job chains:
#
#   BURST_SUBNET_ID=$(terraform output -raw burst_subnet_id) \
#   EFS_SG_ID=$(terraform output -raw efs_sg_id) \
#   AWS_REGION=us-west-2 \
#     bash /opt/slurm/etc/workloads/jobs/scenario3/submit-chain.sh --granularity per-job
#
# burst_subnet_id is the cloud-side subnet where burst nodes run. The ephemeral
# EFS mount target is created here — NOT in the on-prem subnet — matching what
# would happen in a real hybrid environment.

output "burst_subnet_id" {
  description = "Cloud burst subnet B (us-west-2b) where burst nodes run. The ephemeral EFS mount target is created here, not in the on-prem subnet."
  value       = local.cloud_subnet_b_id
}

output "efs_sg_id" {
  description = "EFS security group ID — required by job1 when creating the ephemeral EFS mount target"
  value       = data.aws_security_group.efs.id
}
