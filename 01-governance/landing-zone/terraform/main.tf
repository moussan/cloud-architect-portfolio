###############################################################################
# Landing Zone — main.tf
# Author  : Moussa El Najmi <moussan@gmail.com>
# Purpose : Provisions the full AWS Organisational structure for the landing zone:
#           - AWS Organisation (all features)
#           - Organisational Units (Security, Infrastructure, Workloads, Prod, Non-Prod, Sandbox)
#           - Member accounts (Log Archive, Security Tooling, Shared Services, Prod×2, Dev, Staging, Sandbox)
#           - Service Control Policies (6 policies)
#           - Tag Policy
#           - Policy type enablement (SCP, Tag, Backup)
#
# IMPORTANT: This file MUST be applied from the management account with
#            OrganizationAccountAccessRole or equivalent.
#
# IMPORTANT: The S3 backend bucket and DynamoDB table must exist BEFORE
#            running `terraform init`. Create them with the bootstrap module
#            or manually before first use.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }

  # Why S3 backend? State must be centralised, encrypted, and concurrency-safe.
  # Local state cannot be shared across team members and is lost if the machine is lost.
  # DynamoDB locking prevents two engineers from running `terraform apply` simultaneously,
  # which would corrupt the state file.
  backend "s3" {
    bucket         = var.terraform_state_bucket
    key            = "landing-zone/terraform.tfstate"
    region         = var.terraform_state_region
    encrypt        = true
    dynamodb_table = var.terraform_state_lock_table
    kms_key_id     = var.terraform_state_kms_key_arn # Explicit KMS key — do not rely on SSE-S3
  }
}

###############################################################################
# Provider
###############################################################################

provider "aws" {
  region = var.primary_region

  default_tags {
    tags = var.default_tags
  }
}

###############################################################################
# AWS Organisation
###############################################################################

# Why ALL_FEATURES? The CONSOLIDATED_BILLING feature set only enables cost
# aggregation. ALL_FEATURES enables SCPs, tag policies, backup policies, and
# AI services opt-out policies. This is a one-way upgrade (you cannot downgrade),
# but there is never a valid reason to operate an enterprise AWS organisation
# without all features. Enable it from the start.
resource "aws_organizations_organization" "this" {
  feature_set = var.org_feature_set # Default: "ALL_FEATURES"

  # Enable all policy types at the organisation level.
  # SERVICE_CONTROL_POLICY : Hard permission boundaries at account/OU level
  # TAG_POLICY             : Enforce consistent tagging across all accounts
  # BACKUP_POLICY          : Centralised backup plan management
  enabled_policy_types = [
    "SERVICE_CONTROL_POLICY",
    "TAG_POLICY",
    "BACKUP_POLICY",
  ]
}

###############################################################################
# Organisational Units
###############################################################################

# WHY: OUs are policy containers. The structure below mirrors distinct security
# and compliance domains — not team structures. Application teams own accounts;
# OUs define the policy bands those accounts operate under.

# Security OU — strictest policies. Contains accounts used for centralised
# security monitoring and immutable audit logging. Application workloads NEVER
# run here. The security team owns these accounts.
resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = aws_organizations_organization.this.roots[0].id

  tags = {
    Purpose = "Security and audit accounts"
  }
}

# Infrastructure OU — shared services that are consumed by workload accounts
# (Transit Gateway, Route 53 Resolver, Shared VPCs, AD Connector).
# These are platform primitives, not business workloads.
resource "aws_organizations_organizational_unit" "infrastructure" {
  name      = "Infrastructure"
  parent_id = aws_organizations_organization.this.roots[0].id

  tags = {
    Purpose = "Shared infrastructure services"
  }
}

# Workloads OU — parent container for production and non-production sub-OUs.
# Having a parent Workloads OU allows attaching SCPs that apply to all workload
# accounts regardless of environment, while child OUs add environment-specific
# policies on top.
resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = aws_organizations_organization.this.roots[0].id

  tags = {
    Purpose = "Parent OU for all workload accounts"
  }
}

# Production OU — strictest workload policies. All controls that apply to
# Workloads OU also apply here, plus production-specific restrictions
# (e.g., no unencrypted databases, no public S3).
resource "aws_organizations_organizational_unit" "production" {
  name      = "Production"
  parent_id = aws_organizations_organizational_unit.workloads.id

  tags = {
    Purpose     = "Production workload accounts"
    Environment = "prod"
  }
}

# Non-Prod OU — development and staging accounts. Same data residency and
# region controls as production, but allows slightly more flexibility
# (e.g., engineers can create resources not yet approved for production).
resource "aws_organizations_organizational_unit" "non_prod" {
  name      = "NonProd"
  parent_id = aws_organizations_organizational_unit.workloads.id

  tags = {
    Purpose     = "Non-production workload accounts"
    Environment = "non-prod"
  }
}

# Sandbox OU — maximum autonomy within cost guardrails. Engineers can
# explore new services here without affecting other environments. Resources
# are tagged with expiry dates via tag policy and cleaned up automatically.
resource "aws_organizations_organizational_unit" "sandbox" {
  name      = "Sandbox"
  parent_id = aws_organizations_organization.this.roots[0].id

  tags = {
    Purpose = "Individual engineer exploration accounts"
  }
}

###############################################################################
# Member Accounts
###############################################################################

# WHY: Each account is a separate billing entity and security boundary.
# Never use a single account for multiple workloads or environments.
# Each account below has a dedicated email — AWS requires unique email addresses
# per account. Use email aliases (e.g., aws+log-archive@example.com) if needed.

# Log Archive Account — Immutable audit trail for the entire organisation.
# CloudTrail, VPC Flow Logs, Config snapshots, and S3 access logs from all
# accounts are shipped here. The DenyDeleteLogs SCP on the Security OU prevents
# anyone from tampering with these logs.
resource "aws_organizations_account" "log_archive" {
  name      = "log-archive"
  email     = var.log_archive_email
  parent_id = aws_organizations_organizational_unit.security.id

  # Why close_on_deletion = false? AWS account closure is permanent and has
  # a 90-day waiting period. Protect against accidental Terraform destroy
  # deleting a production account.
  close_on_deletion = false

  tags = {
    AccountType = "security"
    Purpose     = "Centralised immutable audit log storage"
  }
}

# Security Tooling Account — Hosts GuardDuty (delegated admin), Security Hub
# (aggregator), Inspector, Macie, and IAM Access Analyzer at the org level.
# Centralising security tools here means the security team has a single pane
# of glass without needing console access to every workload account.
resource "aws_organizations_account" "security_tooling" {
  name      = "security-tooling"
  email     = var.security_tooling_email
  parent_id = aws_organizations_organizational_unit.security.id

  close_on_deletion = false

  tags = {
    AccountType = "security"
    Purpose     = "GuardDuty, Security Hub, Inspector, Macie"
  }
}

# Shared Services Account — Hosts networking primitives that are shared across
# workload accounts: Transit Gateway, Route 53 Resolver, AWS Directory Service,
# and optionally a shared ingress VPC. Centralising networking here prevents
# TGW sprawl and gives the networking team a single account to manage.
resource "aws_organizations_account" "shared_services" {
  name      = "shared-services"
  email     = var.shared_services_email
  parent_id = aws_organizations_organizational_unit.infrastructure.id

  close_on_deletion = false

  tags = {
    AccountType = "infrastructure"
    Purpose     = "Transit Gateway, Route 53, shared networking"
  }
}

# Production App 1 Account — First production workload account. Application
# teams own this account and operate within the guardrails set by the
# Production OU SCPs.
resource "aws_organizations_account" "prod_app1" {
  name      = "prod-app-1"
  email     = var.prod_app1_email
  parent_id = aws_organizations_organizational_unit.production.id

  close_on_deletion = false

  tags = {
    AccountType = "workload"
    Environment = "prod"
    Application = "app-1"
  }
}

# Production App 2 Account — Second production workload account.
resource "aws_organizations_account" "prod_app2" {
  name      = "prod-app-2"
  email     = var.prod_app2_email
  parent_id = aws_organizations_organizational_unit.production.id

  close_on_deletion = false

  tags = {
    AccountType = "workload"
    Environment = "prod"
    Application = "app-2"
  }
}

# Development Account — Primary development environment. Engineers deploy
# feature branches and integration tests here. Looser than production but
# still governed: region-locked, no public S3, IMDSv2 required.
resource "aws_organizations_account" "dev" {
  name      = "dev"
  email     = var.dev_email
  parent_id = aws_organizations_organizational_unit.non_prod.id

  close_on_deletion = false

  tags = {
    AccountType = "workload"
    Environment = "dev"
  }
}

# Staging Account — Pre-production environment. Mirrors production configuration
# as closely as possible for final validation before releases. Should have the
# same SCP restrictions as production.
resource "aws_organizations_account" "staging" {
  name      = "staging"
  email     = var.staging_email
  parent_id = aws_organizations_organizational_unit.non_prod.id

  close_on_deletion = false

  tags = {
    AccountType = "workload"
    Environment = "staging"
  }
}

# Sandbox Account — Shared exploration account for engineers. No production
# data ever. Resources are auto-tagged with expiry and cleaned up by an
# account nuke Lambda that runs weekly.
resource "aws_organizations_account" "sandbox" {
  name      = "sandbox"
  email     = var.sandbox_email
  parent_id = aws_organizations_organizational_unit.sandbox.id

  close_on_deletion = false

  tags = {
    AccountType = "sandbox"
    Environment = "sandbox"
  }
}

###############################################################################
# Service Control Policies — Data Sources (Policy JSON)
###############################################################################

# WHY deny-list strategy? AWS releases new services constantly. An allow-list
# requires updates every time your team wants to adopt a new service. A deny-list
# only needs updates when you want to explicitly block something. The operational
# overhead is dramatically lower while still providing strong guardrails.

# SCP 1: Deny actions outside allowed regions
# WHY: Data residency requirements (PIPEDA in Canada) and blast-radius containment.
# Using NotAction instead of Action to exempt global services (IAM, Route 53,
# CloudFront, etc.) that are not region-scoped and would break if region-denied.
data "aws_iam_policy_document" "deny_non_allowed_regions" {
  statement {
    sid    = "DenyNonAllowedRegions"
    effect = "Deny"

    not_actions = [
      "iam:*",
      "organizations:*",
      "route53:*",
      "budgets:*",
      "waf:*",
      "cloudfront:*",
      "globalaccelerator:*",
      "importexport:*",
      "support:*",
      "sts:*",
      "health:*",
      "account:*",
    ]

    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = var.allowed_regions
    }
  }
}

# SCP 2: Deny leaving the organisation
# WHY: Without this, a compromised root user could remove the account from the
# organisation, escaping all SCPs, guardrails, and centralised logging.
# This is a foundational control — it should be the first SCP applied.
data "aws_iam_policy_document" "deny_leave_organization" {
  statement {
    sid       = "DenyLeaveOrganization"
    effect    = "Deny"
    actions   = ["organizations:LeaveOrganization"]
    resources = ["*"]
  }
}

# SCP 3: Require IMDSv2 on all EC2 instances
# WHY: IMDSv1 is vulnerable to SSRF attacks that allow malicious applications
# to steal EC2 instance credentials via the metadata endpoint (169.254.169.254).
# The 2019 Capital One breach exploited exactly this vector. IMDSv2 requires a
# session-oriented PUT request with a TTL header, which SSRF cannot replicate.
data "aws_iam_policy_document" "require_imdsv2" {
  statement {
    sid    = "RequireIMDSv2"
    effect = "Deny"
    actions = [
      "ec2:RunInstances",
      "ec2:ModifyInstanceMetadataOptions",
    ]
    resources = ["arn:aws:ec2:*:*:instance/*"]

    condition {
      test     = "StringNotEquals"
      variable = "ec2:MetadataHttpTokens"
      values   = ["required"]
    }
  }
}

# SCP 4: Deny root account actions
# WHY: The AWS root user has unrestricted access and bypasses most IAM controls.
# Human operators should NEVER use the root user for routine tasks. This SCP
# prevents root usage except for the specific tasks that require it (e.g.,
# changing the support plan, closing the account).
data "aws_iam_policy_document" "deny_root_account_actions" {
  statement {
    sid    = "DenyRootAccountActions"
    effect = "Deny"
    actions = [
      "iam:CreateAccessKey",
      "iam:CreateVirtualMFADevice",
      "iam:DeleteVirtualMFADevice",
      "iam:DeactivateMFADevice",
      "iam:EnableMFADevice",
      "iam:ResyncMFADevice",
    ]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::*:root"]
    }
  }
}

# SCP 5: Require S3 server-side encryption
# WHY: Unencrypted S3 objects are a data exfiltration and compliance risk.
# This SCP ensures that any PutObject call that does not specify SSE-S3,
# SSE-KMS, or SSE-C encryption is denied at the organisational boundary —
# even if a bucket policy or IAM policy would allow it.
data "aws_iam_policy_document" "require_s3_sse" {
  statement {
    sid    = "DenyS3PutWithoutEncryption"
    effect = "Deny"
    actions = [
      "s3:PutObject",
    ]
    resources = ["arn:aws:s3:::*/*"]

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["true"]
    }
  }
}

# SCP 6: Deny public S3 buckets (block public ACLs and policies)
# WHY: Publicly accessible S3 buckets are one of the most common causes of
# data breaches in AWS. This SCP prevents anyone from creating or modifying
# public S3 bucket ACLs or policies, regardless of what their IAM policy allows.
# The S3 Block Public Access setting can be applied per-account, but an SCP
# ensures it cannot be removed by any account administrator.
data "aws_iam_policy_document" "deny_public_s3" {
  statement {
    sid    = "DenyS3PublicACL"
    effect = "Deny"
    actions = [
      "s3:PutBucketAcl",
      "s3:PutObjectAcl",
    ]
    resources = ["arn:aws:s3:::*", "arn:aws:s3:::*/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values = [
        "public-read",
        "public-read-write",
        "authenticated-read",
      ]
    }
  }

  statement {
    sid    = "DenyS3PublicPolicy"
    effect = "Deny"
    actions = [
      "s3:PutBucketPublicAccessBlock",
    ]
    resources = ["arn:aws:s3:::*"]

    condition {
      test     = "StringEquals"
      variable = "s3:PublicAccessBlockConfiguration.BlockPublicAcls"
      values   = ["false"]
    }
  }
}

###############################################################################
# Service Control Policies — Resources
###############################################################################

resource "aws_organizations_policy" "deny_non_allowed_regions" {
  name        = "DenyNonAllowedRegions"
  description = "Prevents any action in regions not in the approved list. Exempts global services (IAM, Route 53, CloudFront)."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_non_allowed_regions.json
}

resource "aws_organizations_policy" "deny_leave_organization" {
  name        = "DenyLeaveOrganization"
  description = "Prevents any principal from removing an account from the organisation. Foundational control."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_leave_organization.json
}

resource "aws_organizations_policy" "require_imdsv2" {
  name        = "RequireIMDSv2"
  description = "Requires all EC2 instances to use IMDSv2 (session-oriented). Prevents SSRF-based credential theft."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.require_imdsv2.json
}

resource "aws_organizations_policy" "deny_root_account_actions" {
  name        = "DenyRootAccountActions"
  description = "Prevents the root user from creating access keys or managing MFA devices. Root actions must go through the break-glass process."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_root_account_actions.json
}

resource "aws_organizations_policy" "require_s3_sse" {
  name        = "RequireS3SSE"
  description = "Denies S3 PutObject calls that do not include a server-side encryption header."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.require_s3_sse.json
}

resource "aws_organizations_policy" "deny_public_s3" {
  name        = "DenyPublicS3Buckets"
  description = "Prevents creation of public S3 ACLs and prevents disabling S3 Block Public Access."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_public_s3.json
}

###############################################################################
# SCP Attachments
###############################################################################

# Attach DenyLeaveOrganization to the ROOT — this must apply to every account
# in the organisation without exception. There is no scenario where an account
# should be able to leave the organisation without a deliberate management-level
# action from the management account.
resource "aws_organizations_policy_attachment" "deny_leave_org_root" {
  policy_id = aws_organizations_policy.deny_leave_organization.id
  target_id = aws_organizations_organization.this.roots[0].id
}

# Attach DenyNonAllowedRegions to the ROOT — data residency applies to all accounts.
resource "aws_organizations_policy_attachment" "deny_non_allowed_regions_root" {
  policy_id = aws_organizations_policy.deny_non_allowed_regions.id
  target_id = aws_organizations_organization.this.roots[0].id
}

# Attach RequireIMDSv2 to the ROOT — IMDSv2 requirement applies everywhere.
resource "aws_organizations_policy_attachment" "require_imdsv2_root" {
  policy_id = aws_organizations_policy.require_imdsv2.id
  target_id = aws_organizations_organization.this.roots[0].id
}

# Attach DenyRootAccountActions to the ROOT.
resource "aws_organizations_policy_attachment" "deny_root_actions_root" {
  policy_id = aws_organizations_policy.deny_root_account_actions.id
  target_id = aws_organizations_organization.this.roots[0].id
}

# Attach RequireS3SSE to the Workloads OU and Security OU.
# Sandbox gets slightly more flexibility (engineers may create unencrypted buckets
# for testing), but all workload accounts must enforce encryption.
resource "aws_organizations_policy_attachment" "require_s3_sse_workloads" {
  policy_id = aws_organizations_policy.require_s3_sse.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_policy_attachment" "require_s3_sse_security" {
  policy_id = aws_organizations_policy.require_s3_sse.id
  target_id = aws_organizations_organizational_unit.security.id
}

resource "aws_organizations_policy_attachment" "require_s3_sse_infrastructure" {
  policy_id = aws_organizations_policy.require_s3_sse.id
  target_id = aws_organizations_organizational_unit.infrastructure.id
}

# Attach DenyPublicS3 to the ROOT — no account in this organisation should ever
# have a public S3 bucket. This is non-negotiable.
resource "aws_organizations_policy_attachment" "deny_public_s3_root" {
  policy_id = aws_organizations_policy.deny_public_s3.id
  target_id = aws_organizations_organization.this.roots[0].id
}

###############################################################################
# Tag Policy
###############################################################################

# WHY: Without a tag policy, teams apply tags inconsistently:
# Environment=prod, Environment=Prod, Environment=PROD, env=production...
# This makes cost allocation reports, compliance queries, and automation scripts
# brittle. The tag policy enforces a controlled vocabulary for key tags.
resource "aws_organizations_policy" "tag_policy" {
  name        = "OrganisationTagPolicy"
  description = "Enforces consistent tag keys and values across all AWS accounts in the organisation."
  type        = "TAG_POLICY"

  content = jsonencode({
    tags = {
      Environment = {
        tag_key = {
          "@@assign" = "Environment"
        }
        tag_value = {
          "@@assign" = [
            "prod",
            "staging",
            "dev",
            "sandbox",
            "shared",
          ]
        }
        enforced_for = {
          "@@assign" = [
            "ec2:instance",
            "s3:bucket",
            "rds:db",
            "lambda:function",
            "ecs:cluster",
          ]
        }
      }
      Owner = {
        tag_key = {
          "@@assign" = "Owner"
        }
        enforced_for = {
          "@@assign" = [
            "ec2:instance",
            "s3:bucket",
            "rds:db",
          ]
        }
      }
      CostCenter = {
        tag_key = {
          "@@assign" = "CostCenter"
        }
        enforced_for = {
          "@@assign" = [
            "ec2:instance",
            "s3:bucket",
            "rds:db",
          ]
        }
      }
    }
  })
}

resource "aws_organizations_policy_attachment" "tag_policy_root" {
  policy_id = aws_organizations_policy.tag_policy.id
  target_id = aws_organizations_organization.this.roots[0].id
}
