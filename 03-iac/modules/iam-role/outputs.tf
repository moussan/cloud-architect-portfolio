################################################################################
# IAM Role Module — Outputs
#
# Every resource ARN, ID, and name is exposed. Consumers should never
# need to reconstruct identifiers from naming conventions.
################################################################################

output "role_arn" {
  description = "IAM role ARN. Use in trust policies of other roles (cross-account), resource-based policies (S3, KMS, SQS), and iam:PassRole permissions."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "IAM role name. Use in aws_iam_role_policy_attachment resources and AWS CLI commands."
  value       = aws_iam_role.this.name
}

output "role_id" {
  description = "IAM role unique ID (AROAXXXXXXXXXXXXXXXXX). Stable across role renames — use in policies where you need an ID that won't change even if the role is re-created with the same name."
  value       = aws_iam_role.this.unique_id
}

output "role_path" {
  description = "IAM path of the role. Useful for listing roles in a specific path."
  value       = aws_iam_role.this.path
}

output "instance_profile_arn" {
  description = "EC2 instance profile ARN. Use in Launch Templates (iam_instance_profile.arn) and EC2 instance configurations. Empty string if create_instance_profile = false."
  value       = var.create_instance_profile ? aws_iam_instance_profile.this[0].arn : ""
}

output "instance_profile_name" {
  description = "EC2 instance profile name. Use in aws_launch_configuration and direct EC2 API calls. Empty string if create_instance_profile = false."
  value       = var.create_instance_profile ? aws_iam_instance_profile.this[0].name : ""
}

output "instance_profile_id" {
  description = "EC2 instance profile unique ID. Empty string if create_instance_profile = false."
  value       = var.create_instance_profile ? aws_iam_instance_profile.this[0].unique_id : ""
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN. Use as oidc_provider_arn in subsequent iam-role module calls that need GitHub trust. Empty string if create_github_oidc_provider = false."
  value       = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : ""
}

output "assume_role_policy" {
  description = "The trust policy JSON document. Useful for debugging or for applying the same trust to a different role."
  value       = aws_iam_role.this.assume_role_policy
}
