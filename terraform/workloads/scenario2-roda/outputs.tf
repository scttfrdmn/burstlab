output "results_bucket" {
  description = "S3 bucket for job results. Pass as RESULTS_BUCKET to job scripts."
  value       = aws_s3_bucket.results.bucket
}

output "roda_bucket" {
  description = "RODA source bucket configured for this deployment"
  value       = var.roda_bucket
}
