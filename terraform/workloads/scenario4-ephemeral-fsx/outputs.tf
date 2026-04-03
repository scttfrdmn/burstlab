# Pass these as environment variables when submitting job chains:
#
#   S3_DATA_BUCKET=$(terraform output -raw s3_data_bucket) \
#   CLOUD_SUBNET_A_ID=$(terraform output -raw cloud_subnet_a_id) \
#   FSX_SG_ID=$(terraform output -raw fsx_sg_id) \
#   FSX_STORAGE_GB=1200 AWS_REGION=us-west-2 \
#     bash /opt/slurm/etc/workloads/jobs/scenario4/submit-chain.sh \
#     --granularity per-job --s3-data-prefix my-dataset/

output "s3_data_bucket" {
  description = "S3 bucket for FSx data repository (input data and results)"
  value       = aws_s3_bucket.fsx_data.bucket
}

output "cloud_subnet_a_id" {
  description = "Cloud burst subnet A — required by job1 when creating the FSx filesystem"
  value       = local.cloud_subnet_a_id
}

output "fsx_sg_id" {
  description = "Security group for FSx filesystem — uses burst node SG (already allows VPC traffic)"
  value       = data.aws_security_group.burst.id
}
