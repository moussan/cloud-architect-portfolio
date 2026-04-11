###############################################################################
# State Backend — outputs.tf
###############################################################################

output "state_bucket_name" {
  description = "S3 bucket name. Use as 'bucket' in all backend configurations."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "S3 bucket ARN. Use in IAM policies for Terraform CI roles."
  value       = aws_s3_bucket.state.arn
}

output "state_bucket_region" {
  description = "Region of the state bucket. Use as 'region' in all backend configurations."
  value       = var.region
}

output "dynamodb_table_name" {
  description = "DynamoDB table name. Use as 'dynamodb_table' in all backend configurations."
  value       = aws_dynamodb_table.state_lock.name
}

output "kms_key_arn" {
  description = "KMS CMK ARN for the state bucket. Use as 'kms_key_id' in backend configurations."
  value       = aws_kms_key.state.arn
}

output "kms_key_alias" {
  description = "KMS key alias — shorthand reference for backend 'kms_key_id'."
  value       = aws_kms_alias.state.name
}
