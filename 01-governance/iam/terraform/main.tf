###############################################################################
# IAM Baseline — main.tf
# Author  : Moussa El Najmi <moussan@gmail.com>
# Purpose : Provisions the IAM security baseline for a member account.
#           This module runs in EACH member account (not the management account)
#           to establish the security posture required by the organisation.
#
#           Provisions:
#             - IAM account alias
#             - IAM password policy
#             - Break-glass admin role (MFA required)
#             - Read-only cross-account role for security tooling
#             - IAM Access Analyzer (account-level)
#             - Organisation-level CloudTrail
#             - AWS Config recorder and delivery channel
#
# Authentication: Assumes the TerraformExecutionRole in the target account.
# Apply this in each member account by configuring the provider with assume_role.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}

provider "aws" {
  region = var.region

  # Assume the Terraform execution role in the target account.
  # This role is created by the landing zone StackSet in each member account.
  assume_role {
    role_arn = "arn:aws:iam::${var.account_id}:role/TerraformExecutionRole"
  }

  default_tags {
    tags = var.default_tags
  }
}

###############################################################################
# IAM Account Alias
###############################################################################

# WHY: The account alias replaces the numeric account ID in the sign-in URL.
# Instead of https://123456789012.signin.aws.amazon.com/console, users see
# https://my-org-prod.signin.aws.amazon.com/console. More importantly, it
# makes CloudTrail logs and Cost Explorer entries readable — you know which
# account you are looking at without a lookup table.
resource "aws_iam_account_alias" "this" {
  account_alias = var.account_alias
}

###############################################################################
# IAM Password Policy
###############################################################################

# WHY: Even in an Identity Center world, there may be legacy IAM users or
# emergency break-glass IAM users. The password policy ensures their credentials
# meet minimum complexity requirements. This is also a CIS AWS Benchmark control
# (CIS 1.5–1.11) and required by most compliance frameworks.
resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 16 # CIS requires >= 14; 16 is better
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  password_reuse_prevention      = 24    # Block the last 24 passwords
  max_password_age               = 90    # Require rotation every 90 days
  hard_expiry                    = false # Locked-out users can still reset via console
}

###############################################################################
# Break-Glass Admin Role
###############################################################################

# WHY: Even with Identity Center, there are scenarios where Identity Center
# is unavailable (IdP outage, CT misconfiguration) and an engineer needs
# direct console access to remediate. The break-glass role provides this
# escape hatch without requiring long-lived IAM user credentials.
#
# Access to this role is restricted by:
#   1. Trust policy: Only principals from the management account can assume it
#   2. MFA condition: Must have MFA active to assume this role
#   3. External ID: Prevents confused-deputy attacks if trust policy is broad
#
# Process: Break-glass credentials are stored in a physical safe or a
# restricted Secrets Manager secret. Every use generates a CloudTrail event
# and triggers a PagerDuty/SNS alert.

data "aws_iam_policy_document" "break_glass_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.management_account_id}:root"]
    }

    # MFA must be active — not just registered. The principal must have
    # authenticated with MFA in the current session.
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }

    # ExternalId prevents confused-deputy attacks from the management account.
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.break_glass_external_id]
    }
  }
}

resource "aws_iam_role" "break_glass_admin" {
  name                 = "BreakGlassAdminRole"
  description          = "Emergency admin access. Requires MFA. Every assumption triggers a CloudWatch alarm. Review use within 24 hours."
  assume_role_policy   = data.aws_iam_policy_document.break_glass_trust.json
  max_session_duration = 3600 # 1 hour — short sessions for privileged access

  tags = {
    Purpose          = "break-glass"
    SensitivityLevel = "critical"
  }
}

resource "aws_iam_role_policy_attachment" "break_glass_admin" {
  role       = aws_iam_role.break_glass_admin.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

###############################################################################
# Read-Only Cross-Account Role for Security Tooling
###############################################################################

# WHY: The Security Tooling account (GuardDuty, Security Hub, Inspector) needs
# read access to resources in each member account for findings and inventory.
# Instead of creating IAM users in each account, a cross-account assume-role
# pattern is used. The Security Tooling account assumes this role to read
# resource configurations, CloudTrail logs, and Config data.

data "aws_iam_policy_document" "security_audit_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.security_tooling_account_id}:root"]
    }

    # ExternalId scoped to this specific account — prevents the Security Tooling
    # account from assuming this role in the wrong member account.
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = ["security-audit-${var.account_id}"]
    }
  }
}

resource "aws_iam_role" "security_audit" {
  name                 = "SecurityAuditCrossAccountRole"
  description          = "Read-only access for Security Tooling account. Used by GuardDuty, Security Hub, and IAM Access Analyzer."
  assume_role_policy   = data.aws_iam_policy_document.security_audit_trust.json
  max_session_duration = 3600

  tags = {
    Purpose = "security-audit"
  }
}

resource "aws_iam_role_policy_attachment" "security_audit_readonly" {
  role       = aws_iam_role.security_audit.name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

resource "aws_iam_role_policy_attachment" "security_audit_view_only" {
  role       = aws_iam_role.security_audit.name
  policy_arn = "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"
}

###############################################################################
# IAM Access Analyzer
###############################################################################

# WHY: Access Analyzer continuously monitors resource-based policies (S3 bucket
# policies, IAM role trust policies, KMS key policies, etc.) and alerts when
# resources are accessible from outside your account or organisation.
# Without this, a misconfigured bucket policy granting public access could
# go undetected for months.
#
# Account-level analyzer — findings include resources shared with any external
# principal. The security tooling account has an org-level analyzer as well,
# which uses the organisation as the zone of trust (cross-account access within
# the org is not flagged as external).
resource "aws_accessanalyzer_analyzer" "this" {
  analyzer_name = "${var.account_alias}-access-analyzer"
  type          = "ACCOUNT"

  tags = {
    Purpose = "Continuously monitor resource-based policies for unintended external access"
  }
}

###############################################################################
# CloudTrail
###############################################################################

# WHY: CloudTrail is the non-negotiable audit log for AWS API activity. Without it,
# you cannot answer "who did this?" after an incident. The organisation-level trail
# (created in the management account) captures API calls from all member accounts.
# This account-level trail supplements it for any account-specific analysis.
#
# Key settings:
#   - S3 bucket in Log Archive account (separate account = tamper-resistant)
#   - SSE-KMS encryption (SSE-S3 is weaker; KMS gives you key control)
#   - Log file validation (detect if log files are modified or deleted)
#   - Include global service events (captures IAM, STS, Route 53 calls)
#   - Multi-region trail (captures calls in all regions, not just the trail's region)

resource "aws_cloudtrail" "this" {
  name                          = "${var.account_alias}-cloudtrail"
  s3_bucket_name                = var.log_archive_bucket_name # Bucket in Log Archive account
  s3_key_prefix                 = "cloudtrail/${var.account_id}"
  include_global_service_events = true                       # Captures IAM, STS, Route 53
  is_multi_region_trail         = true                       # Captures events in all regions
  enable_log_file_validation    = true                       # Detects tampered or deleted log files
  kms_key_id                    = var.cloudtrail_kms_key_arn # Customer-managed KMS key

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    # Capture S3 data events — who accessed which objects.
    # This is critical for data exfiltration detection.
    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::"] # All buckets
    }
  }

  tags = {
    Purpose = "Account-level API audit trail"
  }
}

###############################################################################
# AWS Config
###############################################################################

# WHY: AWS Config records the configuration state of every resource in your
# account over time. It answers "what did this resource look like at 3pm on
# Tuesday?" which is essential for incident investigation and compliance audits.
# Config also evaluates resources against Config rules for continuous compliance
# monitoring.

resource "aws_config_configuration_recorder" "this" {
  name     = "default"
  role_arn = aws_iam_role.config_recorder.arn

  recording_group {
    all_supported                 = true # Record all resource types
    include_global_resource_types = true # Include IAM users, roles, policies
  }
}

# WHY a dedicated IAM role for Config? Config needs permission to read resource
# configurations and write to the delivery channel. Scoping this to AWS-managed
# policies for Config limits what the role can do.
resource "aws_iam_role" "config_recorder" {
  name               = "AWSConfigRecorderRole"
  assume_role_policy = data.aws_iam_policy_document.config_trust.json

  tags = {
    Purpose = "AWS Config configuration recorder"
  }
}

data "aws_iam_policy_document" "config_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "config_recorder" {
  role       = aws_iam_role.config_recorder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# Config delivery channel — sends configuration snapshots and compliance
# notifications to the Log Archive account S3 bucket and an SNS topic.
resource "aws_config_delivery_channel" "this" {
  name           = "default"
  s3_bucket_name = var.log_archive_bucket_name
  s3_key_prefix  = "config/${var.account_id}"
  sns_topic_arn  = var.config_sns_topic_arn # SNS topic in Log Archive or Security Tooling account

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours" # Daily snapshots in addition to on-change recording
  }

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}
