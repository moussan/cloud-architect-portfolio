###############################################################################
# IAM Baseline — variables.tf
###############################################################################

variable "region" {
  description = "AWS region for the provider."
  type        = string
  default     = "ca-central-1"
}

variable "account_id" {
  description = "AWS account ID of the target member account. Used to construct the TerraformExecutionRole ARN."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "account_alias" {
  description = "IAM account alias for the target account (e.g., 'my-org-prod-app-1'). Replaces the numeric ID in the sign-in URL."
  type        = string
}

variable "management_account_id" {
  description = "AWS account ID of the management account. Used in the break-glass role trust policy."
  type        = string
}

variable "security_tooling_account_id" {
  description = "AWS account ID of the Security Tooling account. Used in the security audit role trust policy."
  type        = string
}

variable "break_glass_external_id" {
  description = "External ID for the break-glass admin role trust policy. Must be unique per account and stored securely. Prevents confused-deputy attacks."
  type        = string
  sensitive   = true
}

variable "log_archive_bucket_name" {
  description = "Name of the S3 bucket in the Log Archive account where CloudTrail logs and Config snapshots are delivered."
  type        = string
}

variable "cloudtrail_kms_key_arn" {
  description = "ARN of the KMS key used to encrypt CloudTrail logs. Must be a customer-managed key in the Log Archive account or a shared key."
  type        = string
}

variable "config_sns_topic_arn" {
  description = "ARN of the SNS topic in the Log Archive or Security Tooling account for Config change notifications."
  type        = string
  default     = null
}

variable "default_tags" {
  description = "Default tags applied to all taggable resources."
  type        = map(string)
  default = {
    ManagedBy  = "terraform"
    Repository = "moussan/cloud-architect-portfolio"
    Pillar     = "governance"
    Module     = "iam-baseline"
  }
}
