################################################################################
# IAM Role Module — Variables
################################################################################

################################################################################
# Core Role Configuration
################################################################################

variable "role_name" {
  type        = string
  description = "IAM role name. Must be unique within the account. Max 64 characters."

  validation {
    condition     = length(var.role_name) >= 1 && length(var.role_name) <= 64
    error_message = "role_name must be between 1 and 64 characters."
  }

  validation {
    condition     = can(regex("^[\\w+=,.@-]+$", var.role_name))
    error_message = "role_name may only contain alphanumeric characters and the following: +=,.@-"
  }
}

variable "path" {
  type        = string
  description = "IAM path for the role. Use paths to organize roles by department, project, or application. Example: '/engineering/data-platform/'."
  default     = "/"

  validation {
    condition     = can(regex("^/[\\w/]*/$", var.path)) || var.path == "/"
    error_message = "path must start and end with '/' and contain only alphanumeric characters and '/'."
  }
}

variable "description" {
  type        = string
  description = "Human-readable description of what this role does and who/what uses it. Include a link to the Terraform module or runbook."
  default     = "Managed by terraform iam-role module."
}

variable "max_session_duration" {
  type        = number
  description = "Maximum session duration in seconds for AssumeRole operations. Min: 900 (15 min), Max: 43200 (12 hours)."
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 900 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 900 and 43200 seconds."
  }
}

variable "permissions_boundary_arn" {
  type        = string
  description = "ARN of an IAM managed policy to use as the permissions boundary. All permissions are capped by the boundary even if the role has broader policies attached."
  default     = ""

  validation {
    condition     = var.permissions_boundary_arn == "" || startswith(var.permissions_boundary_arn, "arn:aws")
    error_message = "permissions_boundary_arn must be empty or a valid IAM policy ARN."
  }
}

################################################################################
# Trust Policy — Service (EC2, Lambda, ECS, etc.)
################################################################################

variable "trusted_service" {
  type        = string
  description = "AWS service principal that can assume this role. Examples: 'ec2.amazonaws.com', 'lambda.amazonaws.com', 'ecs-tasks.amazonaws.com', 'delivery.logs.amazonaws.com'."
  default     = ""

  validation {
    condition     = var.trusted_service == "" || can(regex("^[a-zA-Z0-9.-]+\\.amazonaws\\.com$", var.trusted_service))
    error_message = "trusted_service must be empty or a valid AWS service principal ending in '.amazonaws.com'."
  }
}

################################################################################
# Trust Policy — Cross-Account
################################################################################

variable "trusted_account_id" {
  type        = string
  description = "AWS account ID allowed to assume this role. Leave empty if not creating a cross-account role."
  default     = ""

  validation {
    condition     = var.trusted_account_id == "" || can(regex("^[0-9]{12}$", var.trusted_account_id))
    error_message = "trusted_account_id must be empty or a 12-digit AWS account ID."
  }
}

variable "trusted_role_arn" {
  type        = string
  description = "Specific IAM role ARN in the trusted account. If empty and trusted_account_id is set, any principal in the account can assume this role (then scoped by their own permission to call sts:AssumeRole)."
  default     = ""

  validation {
    condition     = var.trusted_role_arn == "" || startswith(var.trusted_role_arn, "arn:aws")
    error_message = "trusted_role_arn must be empty or a valid IAM role ARN."
  }
}

variable "require_mfa_for_assume_role" {
  type        = bool
  description = "Add a Condition requiring MFA presence on cross-account AssumeRole calls. Only applies when trusted_account_id is set."
  default     = false
}

################################################################################
# Trust Policy — OIDC (GitHub Actions, GitLab, etc.)
################################################################################

variable "oidc_provider_arn" {
  type        = string
  description = "ARN of the existing IAM OIDC Identity Provider. For GitHub Actions, this is the provider created by aws_iam_openid_connect_provider.github."
  default     = ""

  validation {
    condition     = var.oidc_provider_arn == "" || can(regex("^arn:aws.*:iam::[0-9]{12}:oidc-provider/.+$", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be empty or a valid OIDC provider ARN."
  }
}

variable "oidc_subject" {
  type        = string
  description = "Exact OIDC subject claim for StringEquals matching. GitHub Actions: 'repo:ORG/REPO:environment:production'. Use oidc_subject_pattern for wildcard matching."
  default     = ""
}

variable "oidc_subject_pattern" {
  type        = string
  description = "OIDC subject claim pattern for StringLike matching (supports * wildcard). Use for 'any branch in repo': 'repo:ORG/REPO:*'. Cannot be set simultaneously with oidc_subject."
  default     = ""

  validation {
    condition     = var.oidc_subject_pattern == "" || var.oidc_subject_pattern != ""
    error_message = "Set either oidc_subject (exact match) or oidc_subject_pattern (wildcard), not both. Validation of mutual exclusivity is enforced in main.tf via a precondition."
  }
}

variable "oidc_subject_claim" {
  type        = string
  description = "OIDC claim name for the subject. GitHub Actions uses 'token.actions.githubusercontent.com:sub'."
  default     = "token.actions.githubusercontent.com:sub"
}

variable "oidc_audience_claim" {
  type        = string
  description = "OIDC claim name for the audience."
  default     = "token.actions.githubusercontent.com:aud"
}

variable "oidc_audience_value" {
  type        = string
  description = "Expected OIDC audience claim value. GitHub Actions tokens use 'sts.amazonaws.com'."
  default     = "sts.amazonaws.com"
}

variable "create_github_oidc_provider" {
  type        = bool
  description = "Create the GitHub Actions OIDC identity provider in this account. Set to true the first time you add GitHub Actions to an account; set to false if it already exists."
  default     = false
}

################################################################################
# Trust Policy — Additional Statements (Escape Hatch)
################################################################################

variable "additional_trust_statements" {
  type        = list(any)
  description = "Additional raw IAM policy statement maps to append to the trust policy. Use as an escape hatch for trust conditions not covered by the standard variables."
  default     = []
}

################################################################################
# Permissions
################################################################################

variable "managed_policy_arns" {
  type        = list(string)
  description = "List of IAM managed policy ARNs to attach to the role. AWS-managed or customer-managed. Max 10 per role (AWS limit)."
  default     = []

  validation {
    condition     = length(var.managed_policy_arns) <= 10
    error_message = "AWS allows a maximum of 10 managed policies per IAM role. For more permissions, use inline policies or create a custom managed policy that consolidates multiple permission sets."
  }

  validation {
    condition     = alltrue([for arn in var.managed_policy_arns : startswith(arn, "arn:aws")])
    error_message = "All managed_policy_arns must be valid ARNs starting with 'arn:aws'."
  }
}

variable "inline_policy_json" {
  type        = string
  description = "JSON string of an IAM inline policy to embed directly in the role. Use jsonencode() to construct from a map. Leave empty to skip."
  default     = ""

  validation {
    condition     = var.inline_policy_json == "" || can(jsondecode(var.inline_policy_json))
    error_message = "inline_policy_json must be empty or a valid JSON string."
  }
}

################################################################################
# EC2 Instance Profile
################################################################################

variable "create_instance_profile" {
  type        = bool
  description = "Create an EC2 instance profile wrapping this role. Required for EC2 instances to use the role. Not needed for Lambda, ECS tasks, or cross-account roles."
  default     = false
}

variable "instance_profile_name" {
  type        = string
  description = "Name for the instance profile. Defaults to role_name if empty."
  default     = ""

  validation {
    condition     = var.instance_profile_name == "" || (length(var.instance_profile_name) >= 1 && length(var.instance_profile_name) <= 128)
    error_message = "instance_profile_name must be between 1 and 128 characters when set."
  }
}

################################################################################
# Tags
################################################################################

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources. Merged with module-default tags (Module, ManagedBy)."
  default     = {}

  validation {
    condition     = !contains(keys(var.tags), "ManagedBy")
    error_message = "Do not set 'ManagedBy' in var.tags — it is set automatically to 'terraform' by this module."
  }
}
