###############################################################################
# Storage — variables.tf
###############################################################################

variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "bucket_name" {
  type        = string
  description = "Globally unique S3 bucket name."

  validation {
    condition     = length(var.bucket_name) >= 3 && length(var.bucket_name) <= 63
    error_message = "S3 bucket name must be 3-63 characters."
  }

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.bucket_name))
    error_message = "Bucket name must be lowercase alphanumeric with hyphens only."
  }
}

variable "primary_region" {
  type    = string
  default = "us-east-1"
}

variable "secondary_region" {
  type        = string
  description = "AWS region for cross-region replication (DR bucket)."
  default     = "us-west-2"

  # Cross-variable constraint (environment, min/max checks) enforced via precondition in main.tf
}

variable "application_role_arn" {
  type        = string
  description = "IAM role ARN of the application that reads/writes to this bucket. Added to KMS key policy and bucket policy."
}

variable "security_account_id" {
  type        = string
  description = "AWS account ID of the centralized security/audit account. Granted read-only KMS key policy access."
  default     = ""
}

variable "cors_allowed_origins" {
  type        = list(string)
  description = "Origins allowed for CORS. Use your actual app domains, not ['*']."
  default     = ["https://app.example.com"]
}

variable "object_lock_retention_days" {
  type        = number
  description = "Default Object Lock retention period in days (GOVERNANCE mode)."
  default     = 30

  validation {
    condition     = var.object_lock_retention_days >= 1 && var.object_lock_retention_days <= 36500
    error_message = "object_lock_retention_days must be between 1 and 36500 (100 years)."
  }
}

variable "log_retention_days" {
  type        = number
  description = "Days to retain application logs in the bucket before expiration."
  default     = 365
}

variable "tags" {
  type    = map(string)
  default = {}
}
