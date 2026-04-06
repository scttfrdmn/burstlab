# Pass these as environment variables when submitting job chains:
#
#   S3_DATA_BUCKET=$(terraform output -raw s3_data_bucket) \
#   BURST_SUBNET_ID=$(terraform output -raw burst_subnet_id) \
#   FSX_SG_ID=$(terraform output -raw fsx_sg_id) \
#   FSX_STORAGE_GB=1200 AWS_REGION=us-west-2 \
#     bash /opt/slurm/etc/workloads/jobs/scenario4/submit-chain.sh \
#     --granularity per-job --s3-data-prefix my-dataset/
#
# burst_subnet_id is the cloud-side subnet where burst nodes run — FSx must be
# created here, not in the on-prem subnet, to match real hybrid architecture.

output "s3_data_bucket" {
  description = "S3 bucket for FSx data repository (ephemeral — input staging + FSx scratch)"
  value       = aws_s3_bucket.fsx_data.bucket
}

output "s3_results_bucket" {
  description = "S3 bucket for durable results (persists across terraform destroy)"
  value       = aws_s3_bucket.fsx_results.bucket
}

output "burst_subnet_id" {
  description = "Cloud burst subnet B (us-west-2b) where burst nodes run — required by job1 when creating the FSx filesystem"
  value       = local.cloud_subnet_b_id
}

output "fsx_sg_id" {
  description = "Security group for FSx filesystem — uses burst node SG (already allows VPC traffic)"
  value       = data.aws_security_group.burst.id
}
