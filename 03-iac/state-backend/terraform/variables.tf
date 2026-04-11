###############################################################################
# State Backend — variables.tf
###############################################################################

variable "bucket_name" {
  type        = string
  description = "Globally unique S3 bucket name for Terraform state. Example: myorg-tfstate-prod."

  validation {
    condition     = length(var.bucket_name) >= 3 && length(var.bucket_name) <= 63
    error_message = "S3 bucket names must be between 3 and 63 characters."
  }

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.bucket_name))
    error_message = "S3 bucket names must be lowercase, start and end with alphanumeric, and contain only letters, numbers, and hyphens."
  }
}

variable "log_bucket_name" {
  type        = string
  description = "Name for the S3 access log bucket. Defaults to bucket_name + '-logs'."
  default     = ""

  # Computed in locals when left empty — Terraform does not support dynamic defaults
  # referencing other variables directly, so callers may pass "" to use the convention.
}

variable "dynamodb_table_name" {
  type        = string
  description = "DynamoDB table name for state locking. Example: myorg-tfstate-lock."
  default     = ""
}

variable "region" {
  type        = string
  description = "AWS region for all resources."
  default     = "us-east-1"
}

variable "noncurrent_version_days" {
  type        = number
  description = "Number of days to retain noncurrent (overwritten) state file versions."
  default     = 90

  validation {
    condition     = var.noncurrent_version_days >= 30 && var.noncurrent_version_days <= 365
    error_message = "noncurrent_version_days must be between 30 and 365. Less than 30 gives insufficient recovery window; more than 365 rarely adds value."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources. Merged with default module tags."
  default     = {}
}
