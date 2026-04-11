###############################################################################
# Storage — outputs.tf
###############################################################################

output "bucket_name" {
  description = "Primary S3 bucket name."
  value       = aws_s3_bucket.main.bucket
}

output "bucket_arn" {
  description = "Primary S3 bucket ARN. Use in IAM policies and KMS key policies."
  value       = aws_s3_bucket.main.arn
}

output "bucket_regional_domain_name" {
  description = "Regional domain name (e.g., bucket.s3.us-east-1.amazonaws.com). Use for CloudFront origins."
  value       = aws_s3_bucket.main.bucket_regional_domain_name
}

output "replica_bucket_arn" {
  description = "Replica S3 bucket ARN in secondary region."
  value       = aws_s3_bucket.replica.arn
}

output "kms_key_arn" {
  description = "Primary KMS CMK ARN for S3 encryption."
  value       = aws_kms_key.s3.arn
}

output "kms_key_alias" {
  description = "KMS key alias for use in Terraform backend configurations and application configs."
  value       = aws_kms_alias.s3.name
}
