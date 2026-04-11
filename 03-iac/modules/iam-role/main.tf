################################################################################
# IAM Role Module — Reusable Role Factory
#
# This module creates an IAM role with one of four trust policy types:
#
#   1. EC2 instance profile — trusted_service = "ec2.amazonaws.com"
#      + create_instance_profile = true
#
#   2. Lambda execution role — trusted_service = "lambda.amazonaws.com"
#
#   3. Cross-account assume-role — trusted_account_id = "123456789012"
#      + optional: trusted_role_arn for specific role in that account
#
#   4. GitHub Actions OIDC — oidc_provider_arn + oidc_subject
#
# Exactly ONE trust type should be configured per module call.
# Mixing trust types is supported but unusual — add a description
# to the role if you do this.
#
# USAGE EXAMPLES:
#
#   # EC2 instance profile
#   module "app_instance_role" {
#     source = "git::https://github.com/myorg/terraform-modules.git//iam-role?ref=v2.1.0"
#     role_name               = "prod-app-instance-role"
#     trusted_service         = "ec2.amazonaws.com"
#     managed_policy_arns     = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]
#     create_instance_profile = true
#   }
#
#   # GitHub Actions OIDC
#   module "github_actions_role" {
#     source = "git::https://github.com/myorg/terraform-modules.git//iam-role?ref=v2.1.0"
#     role_name         = "github-actions-terraform-prod"
#     oidc_provider_arn = aws_iam_openid_connect_provider.github.arn
#     oidc_subject      = "repo:myorg/myrepo:ref:refs/heads/main"
#     managed_policy_arns = [aws_iam_policy.terraform_deploy.arn]
#   }
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

################################################################################
# Trust Policy Construction
#
# The trust policy defines WHO can assume this role.
# We build it dynamically based on which trust type variables are set.
################################################################################

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  # Determine which trust type is being used
  is_service_trust       = var.trusted_service != ""
  is_cross_account_trust = var.trusted_account_id != ""
  is_oidc_trust          = var.oidc_provider_arn != ""

  # Service trust statement — AWS service (EC2, Lambda, ECS, etc.)
  service_trust_statement = local.is_service_trust ? [{
    Sid    = "AllowServiceAssumeRole"
    Effect = "Allow"
    Principal = {
      Service = var.trusted_service
    }
    Action = "sts:AssumeRole"
    # Condition not added here — services don't support conditions on AssumeRole
    # in most cases. If you need a condition (e.g., source account for cross-service),
    # use inline_trust_policy_statements instead.
  }] : []

  # Cross-account trust statement
  cross_account_trust_statement = local.is_cross_account_trust ? [{
    Sid    = "AllowCrossAccountAssumeRole"
    Effect = "Allow"
    Principal = {
      # If a specific role ARN is provided, scope to that role only.
      # Otherwise, allow any principal in the trusted account.
      AWS = var.trusted_role_arn != "" ? var.trusted_role_arn : "arn:${local.partition}:iam::${var.trusted_account_id}:root"
    }
    Action = "sts:AssumeRole"
    Condition = var.require_mfa_for_assume_role ? {
      Bool = { "aws:MultiFactorAuthPresent" = "true" }
      # WHY MFA condition for cross-account roles?
      # Long-lived access keys in trusted accounts can be compromised.
      # MFA requirement means a stolen key alone is not sufficient to assume
      # this role — the attacker also needs the MFA token.
    } : {}
  }] : []

  # OIDC trust statement — for GitHub Actions, GitLab CI, CircleCI, etc.
  oidc_trust_statement = local.is_oidc_trust ? [{
    Sid    = "AllowOIDCAssumeRole"
    Effect = "Allow"
    Principal = {
      Federated = var.oidc_provider_arn
    }
    Action = "sts:AssumeRoleWithWebIdentity"
    Condition = {
      StringEquals = merge(
        # Audience claim must match sts.amazonaws.com (standard for AWS OIDC)
        { "${var.oidc_audience_claim}" = var.oidc_audience_value },
        # Subject claim scopes to a specific repo/branch/environment
        # GitHub format: "repo:ORG/REPO:ref:refs/heads/main"
        #                "repo:ORG/REPO:environment:production"
        var.oidc_subject != "" ? { "${var.oidc_subject_claim}" = var.oidc_subject } : {},
      )
      StringLike = var.oidc_subject_pattern != "" ? {
        "${var.oidc_subject_claim}" = var.oidc_subject_pattern
        # WHY StringLike instead of StringEquals for pattern?
        # StringLike supports wildcards (* and ?).
        # Use StringEquals for exact matches (preferred — most secure).
        # Use StringLike only when you need wildcards (e.g., any branch in a repo:
        # "repo:myorg/myrepo:*")
      } : {}
    }
  }] : []

  # Combine all trust statements (a role can have multiple principals)
  all_trust_statements = concat(
    local.service_trust_statement,
    local.cross_account_trust_statement,
    local.oidc_trust_statement,
    var.additional_trust_statements,
    # WHY additional_trust_statements?
    # Escape hatch for complex trust policies (e.g., service + cross-account,
    # or conditions we haven't parameterized). Pass raw policy statement maps.
  )

  # Validate at least one trust type is configured
  trust_configured = local.is_service_trust || local.is_cross_account_trust || local.is_oidc_trust || length(var.additional_trust_statements) > 0
}

################################################################################
# IAM Role
################################################################################

resource "aws_iam_role" "this" {
  name        = var.role_name
  path        = var.path
  description = var.description

  max_session_duration = var.max_session_duration
  # WHY 3600 default (1 hour)?
  # Shorter session tokens reduce the window of exposure if they're compromised.
  # For CI/CD pipelines (GitHub Actions), 3600s is sufficient for most Terraform applies.
  # For human console access, 8 hours (28800s) reduces re-authentication friction.
  # For cross-account automation, 1 hour is a reasonable default.

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.all_trust_statements
  })

  permissions_boundary = var.permissions_boundary_arn
  # WHY permissions boundary?
  # In multi-team AWS accounts, a permissions boundary prevents privilege escalation:
  # A team can create IAM roles, but those roles cannot exceed the permissions
  # defined in the boundary policy. Without it, a team with iam:CreateRole could
  # create a role with AdministratorAccess and bypass all controls.

  tags = merge(var.tags, {
    Module    = "iam-role"
    ManagedBy = "terraform"
  })

  lifecycle {
    precondition {
      condition     = local.trust_configured
      error_message = "At least one trust relationship must be configured: trusted_service, trusted_account_id, oidc_provider_arn, or additional_trust_statements."
    }

    precondition {
      condition     = var.max_session_duration >= 900 && var.max_session_duration <= 43200
      error_message = "max_session_duration must be between 900 and 43200 seconds (15 minutes to 12 hours)."
    }
  }
}

################################################################################
# Managed Policy Attachments
################################################################################

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset(var.managed_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
  # WHY for_each on managed_policy_arns?
  # Each attachment is a separate resource with a unique key (the ARN).
  # If one policy is removed from the list, only that attachment is deleted —
  # not all attachments recreated. Using a count index would cause cascading
  # deletes on index reordering.
}

################################################################################
# Inline Policy (Optional)
#
# WHY offer an inline policy?
# Inline policies are embedded in the role — they cannot be accidentally
# detached, and their lifecycle is tied to the role. Use inline policies for:
# - Permissions that are specific to one role and should not be shared
# - Avoiding the AWS limit of 10 managed policy attachments per role
#
# WHY NOT always use inline policies?
# - Cannot be attached to multiple roles — only manageable via this specific role
# - Cannot be found by `aws iam list-policies` — harder to audit
# - Use managed policies when the same permissions apply to multiple roles
################################################################################

resource "aws_iam_role_policy" "inline" {
  count = var.inline_policy_json != "" ? 1 : 0
  # WHY count = 0/1 instead of a separate variable?
  # The inline policy's presence is conditional on whether a JSON string was provided.
  # count = 0 means the resource doesn't exist; count = 1 means it does.

  name   = "${var.role_name}-inline-policy"
  role   = aws_iam_role.this.id
  policy = var.inline_policy_json
}

################################################################################
# EC2 Instance Profile (Optional)
#
# An instance profile is a container for an IAM role that EC2 uses.
# When you launch an EC2 instance with an IAM role, AWS actually attaches
# an instance profile — not the role directly.
#
# WHY is instance profile separate from the role?
# Historical: IAM roles were designed for multiple service types.
# Instance profiles are the EC2-specific wrapper. The same role could be
# used in an instance profile AND in a Lambda execution role, though this
# is unusual and not recommended for least-privilege reasons.
################################################################################

resource "aws_iam_instance_profile" "this" {
  count = var.create_instance_profile ? 1 : 0

  name = var.instance_profile_name != "" ? var.instance_profile_name : var.role_name
  # WHY allow a separate instance profile name?
  # Some naming conventions require different names for role and profile.
  # Default: same name for both — simpler to reason about.

  path = var.path
  role = aws_iam_role.this.name

  tags = merge(var.tags, {
    Module    = "iam-role"
    ManagedBy = "terraform"
  })
}

################################################################################
# GitHub Actions OIDC Provider (Optional)
#
# If you need to CREATE the GitHub OIDC provider (not just reference an existing one),
# set create_github_oidc_provider = true. This is idempotent per account — only one
# provider is needed per account regardless of how many repos use it.
################################################################################

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]
  # WHY sts.amazonaws.com as the client ID?
  # GitHub Actions OIDC tokens are issued with audience = "sts.amazonaws.com"
  # when using the official `aws-actions/configure-aws-credentials` action.
  # This must match exactly — any mismatch and AssumeRoleWithWebIdentity will fail.

  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1",
  "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
  # WHY two thumbprints?
  # AWS rotated the GitHub OIDC thumbprint in 2023. Including both old and new
  # prevents authentication failures during any future rotation.
  # AWS now validates GitHub OIDC tokens against their root CA directly —
  # thumbprints are a legacy mechanism but must still be provided.

  tags = merge(var.tags, {
    Module    = "iam-role"
    ManagedBy = "terraform"
  })
}
