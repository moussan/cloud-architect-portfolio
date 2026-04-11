###############################################################################
# Landing Zone — variables.tf
# All variables used by main.tf. Sensitive values (emails, account IDs) have
# no defaults and must be provided in terraform.tfvars or environment variables.
###############################################################################

###############################################################################
# Backend Configuration
# These are used in the backend block in main.tf (passed via -backend-config
# or as partial backend config). They cannot be variable references in the
# backend block itself (Terraform limitation), but are documented here for
# clarity.
###############################################################################

variable "terraform_state_bucket" {
  description = "Name of the S3 bucket used to store Terraform state. Must exist before running terraform init."
  type        = string
}

variable "terraform_state_region" {
  description = "AWS region where the Terraform state S3 bucket lives."
  type        = string
  default     = "ca-central-1"
}

variable "terraform_state_lock_table" {
  description = "Name of the DynamoDB table used for Terraform state locking. Must exist before running terraform init."
  type        = string
  default     = "terraform-state-lock"
}

variable "terraform_state_kms_key_arn" {
  description = "ARN of the KMS key used to encrypt Terraform state in S3. Using a customer-managed key gives you control over key rotation and deletion."
  type        = string
  default     = null # If null, AWS managed key (SSE-S3) is used. KMS recommended.
}

###############################################################################
# Organisation
###############################################################################

variable "org_feature_set" {
  description = "Feature set for the AWS Organisation. ALL_FEATURES enables SCPs, tag policies, and backup policies. CONSOLIDATED_BILLING only enables cost aggregation. Always use ALL_FEATURES."
  type        = string
  default     = "ALL_FEATURES"

  validation {
    condition     = var.org_feature_set == "ALL_FEATURES"
    error_message = "org_feature_set must be ALL_FEATURES. CONSOLIDATED_BILLING does not support SCPs or tag policies."
  }
}

variable "primary_region" {
  description = "Primary AWS region for the landing zone. Must be one of the allowed_regions."
  type        = string
  default     = "ca-central-1"
}

variable "allowed_regions" {
  description = "List of AWS regions where workloads are permitted to run. The DenyNonAllowedRegions SCP blocks all other regions. Global services (IAM, Route 53, CloudFront) are automatically exempted."
  type        = list(string)
  default     = ["ca-central-1", "us-east-1"]

  validation {
    condition     = length(var.allowed_regions) > 0
    error_message = "allowed_regions must contain at least one region."
  }
}

###############################################################################
# Management Account
###############################################################################

variable "management_account_id" {
  description = "AWS account ID of the management account. Used for documentation and cross-account references."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be a 12-digit AWS account ID."
  }
}

variable "management_account_email" {
  description = "Root email address of the management account. Cannot be changed after account creation."
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.management_account_email))
    error_message = "management_account_email must be a valid email address."
  }
}

###############################################################################
# Member Account Emails
# Each AWS account requires a globally unique email address.
# Use email aliases if your organisation has a single domain:
# e.g., aws+log-archive@example.com, aws+security-tooling@example.com
###############################################################################

variable "log_archive_email" {
  description = "Unique email address for the Log Archive account. This account holds immutable audit logs for the entire organisation."
  type        = string
}

variable "security_tooling_email" {
  description = "Unique email address for the Security Tooling account. This account is the delegated admin for GuardDuty, Security Hub, Inspector, and Macie."
  type        = string
}

variable "shared_services_email" {
  description = "Unique email address for the Shared Services account. This account hosts Transit Gateway, Route 53 Resolver, and other shared networking primitives."
  type        = string
}

variable "prod_app1_email" {
  description = "Unique email address for the first production application account."
  type        = string
}

variable "prod_app2_email" {
  description = "Unique email address for the second production application account."
  type        = string
}

variable "dev_email" {
  description = "Unique email address for the development account."
  type        = string
}

variable "staging_email" {
  description = "Unique email address for the staging account."
  type        = string
}

variable "sandbox_email" {
  description = "Unique email address for the sandbox account."
  type        = string
}

###############################################################################
# Tagging
###############################################################################

variable "default_tags" {
  description = "Default tags applied to all taggable resources provisioned by this module. These supplement the organisation-level tag policy."
  type        = map(string)
  default = {
    ManagedBy  = "terraform"
    Repository = "moussan/cloud-architect-portfolio"
    Pillar     = "governance"
    Module     = "landing-zone"
  }
}
