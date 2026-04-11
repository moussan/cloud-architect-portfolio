###############################################################################
# SCPs — main.tf
# Author  : Moussa El Najmi <moussan@gmail.com>
# Purpose : Defines all 8 production-ready Service Control Policies using
#           aws_iam_policy_document data sources (avoids heredoc JSON,
#           validates syntax at plan time) and aws_organizations_policy resources.
#
# HOW TO USE:
#   This module is called after the landing zone module has created the OU
#   and account structure. It reads OU IDs from the landing zone remote state
#   and attaches SCPs to the appropriate OUs.
#
# IMPORTANT: Apply from the management account. SCPs can only be created
#            and managed from the management account.
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
}

###############################################################################
# Remote State — Read OU IDs from Landing Zone
###############################################################################

data "terraform_remote_state" "landing_zone" {
  backend = "s3"
  config = {
    bucket = var.terraform_state_bucket
    key    = "landing-zone/terraform.tfstate"
    region = var.terraform_state_region
  }
}

locals {
  org_root_id          = data.terraform_remote_state.landing_zone.outputs.org_root_id
  security_ou_id       = data.terraform_remote_state.landing_zone.outputs.security_ou_id
  workloads_ou_id      = data.terraform_remote_state.landing_zone.outputs.workloads_ou_id
  production_ou_id     = data.terraform_remote_state.landing_zone.outputs.production_ou_id
  infrastructure_ou_id = data.terraform_remote_state.landing_zone.outputs.infrastructure_ou_id
}

###############################################################################
# SCP 1: DenyNonAllowedRegions
# Scope: Root (applies to all accounts in the organisation)
# WHY: Data residency requirements under PIPEDA require Canadian data to stay
#      in Canada. us-east-1 is included because certain global services
#      (CloudFront distributions, WAF, ACM for CloudFront) require it.
#      NotAction exempts global services that are not region-scoped.
###############################################################################

data "aws_iam_policy_document" "deny_non_allowed_regions" {
  statement {
    sid    = "DenyNonAllowedRegions"
    effect = "Deny"

    # NotAction exempts these global/meta services from the region restriction.
    # Blocking them would prevent console login, IAM management, billing access,
    # Route 53 operations, and CloudFront distributions.
    not_actions = [
      "a4b:*",
      "account:*",
      "aws-marketplace:*",
      "budgets:*",
      "ce:*",
      "chime:*",
      "cloudfront:*",
      "globalaccelerator:*",
      "health:*",
      "iam:*",
      "importexport:*",
      "lightsail:*",
      "mobileanalytics:*",
      "organizations:*",
      "route53:*",
      "route53domains:*",
      "s3:GetBucketLocation",
      "s3:GetBucketPolicy",
      "s3:ListAllMyBuckets",
      "shield:*",
      "sts:*",
      "support:*",
      "trustedadvisor:*",
      "waf:*",
      "wellarchitected:*",
    ]

    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = var.allowed_regions
    }
  }
}

resource "aws_organizations_policy" "deny_non_allowed_regions" {
  name        = "DenyNonAllowedRegions"
  description = "Blocks API calls in any AWS region not in the approved list (${join(", ", var.allowed_regions)}). Exempts global services. Data residency control."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_non_allowed_regions.json
}

# Attach to Root — applies to all accounts in the organisation.
# Data residency is non-negotiable and applies everywhere.
resource "aws_organizations_policy_attachment" "deny_non_allowed_regions_root" {
  policy_id = aws_organizations_policy.deny_non_allowed_regions.id
  target_id = local.org_root_id
}

###############################################################################
# SCP 2: DenyLeaveOrganization
# Scope: Root (foundational — must apply to every account)
# WHY: A compromised root user could remove the account from the organisation,
#      escaping all SCPs, centralised logging, and consolidated billing.
#      This SCP is the first line of defence against that attack vector.
###############################################################################

data "aws_iam_policy_document" "deny_leave_organization" {
  statement {
    sid       = "DenyLeaveOrganization"
    effect    = "Deny"
    actions   = ["organizations:LeaveOrganization"]
    resources = ["*"]
  }
}

resource "aws_organizations_policy" "deny_leave_organization" {
  name        = "DenyLeaveOrganization"
  description = "Prevents any principal (including root) from removing an account from the AWS Organisation. Foundational control — attach to Root."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_leave_organization.json
}

resource "aws_organizations_policy_attachment" "deny_leave_organization_root" {
  policy_id = aws_organizations_policy.deny_leave_organization.id
  target_id = local.org_root_id
}

###############################################################################
# SCP 3: RequireIMDSv2
# Scope: Root (applies to all EC2 launches and metadata option changes)
# WHY: IMDSv1 is vulnerable to SSRF attacks. The 2019 Capital One breach
#      exploited IMDSv1 to steal EC2 credentials via a misconfigured WAF.
#      IMDSv2 requires a PUT pre-flight request that SSRF cannot replicate.
#      DenyIMDSv2Downgrade prevents running instances from being downgraded.
###############################################################################

data "aws_iam_policy_document" "require_imdsv2" {
  # Deny launching instances without IMDSv2 required
  statement {
    sid    = "RequireIMDSv2OnRunInstances"
    effect = "Deny"
    actions = [
      "ec2:RunInstances",
    ]
    resources = ["arn:aws:ec2:*:*:instance/*"]

    condition {
      test     = "StringNotEquals"
      variable = "ec2:MetadataHttpTokens"
      values   = ["required"]
    }
  }

  # Deny downgrading running instances to IMDSv1 (optional means IMDSv1 allowed)
  statement {
    sid    = "DenyIMDSv2Downgrade"
    effect = "Deny"
    actions = [
      "ec2:ModifyInstanceMetadataOptions",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:MetadataHttpTokens"
      values   = ["optional"]
    }
  }
}

resource "aws_organizations_policy" "require_imdsv2" {
  name        = "RequireIMDSv2"
  description = "Requires all EC2 instances to use IMDSv2 (session-oriented metadata). Prevents SSRF-based credential theft. Blocks both new launches and downgrading running instances."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.require_imdsv2.json
}

resource "aws_organizations_policy_attachment" "require_imdsv2_root" {
  policy_id = aws_organizations_policy.require_imdsv2.id
  target_id = local.org_root_id
}

###############################################################################
# SCP 4: DenyRootAccountActions
# Scope: Root
# WHY: The root user is the most privileged principal in an AWS account.
#      It bypasses IAM policies and has capabilities no other identity has.
#      Establishing persistent root credentials (access keys) or managing
#      MFA via root must be prohibited and driven through a break-glass process.
###############################################################################

data "aws_iam_policy_document" "deny_root_account_actions" {
  statement {
    sid    = "DenyRootAccountActions"
    effect = "Deny"
    actions = [
      "iam:CreateAccessKey",        # No root access keys — ever
      "iam:CreateVirtualMFADevice", # MFA device management goes through break-glass
      "iam:DeleteVirtualMFADevice",
      "iam:DeactivateMFADevice",
      "iam:EnableMFADevice",
      "iam:ResyncMFADevice",
      "iam:UpdateAccountPasswordPolicy", # Password policy managed by IAM baseline module
    ]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::*:root"]
    }
  }
}

resource "aws_organizations_policy" "deny_root_account_actions" {
  name        = "DenyRootAccountActions"
  description = "Prevents the account root user from creating access keys or managing MFA devices. Root usage is reserved for the break-glass process only."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_root_account_actions.json
}

resource "aws_organizations_policy_attachment" "deny_root_account_actions_root" {
  policy_id = aws_organizations_policy.deny_root_account_actions.id
  target_id = local.org_root_id
}

###############################################################################
# SCP 5: RequireS3SSE
# Scope: Workloads OU, Security OU, Infrastructure OU
#        (Sandbox exempt — engineers may test without encryption)
# WHY: Unencrypted S3 objects violate PIPEDA, HIPAA, PCI-DSS, and most
#      compliance frameworks. This SCP denies any PutObject without an
#      encryption header, regardless of bucket default encryption settings.
#      Bucket default encryption is advisory; this SCP is mandatory.
###############################################################################

data "aws_iam_policy_document" "require_s3_sse" {
  # Deny PutObject with no encryption header at all
  statement {
    sid    = "DenyS3PutWithoutEncryptionHeader"
    effect = "Deny"
    actions = [
      "s3:PutObject",
    ]
    resources = ["arn:aws:s3:::*/*"]

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["true"] # Condition is true when the header is absent (null)
    }
  }

  # Deny PutObject with an encryption type not in the approved list
  # (aws:kms = SSE-KMS, AES256 = SSE-S3)
  statement {
    sid    = "DenyS3PutWithNonCompliantEncryption"
    effect = "Deny"
    actions = [
      "s3:PutObject",
    ]
    resources = ["arn:aws:s3:::*/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms", "AES256"]
    }
  }
}

resource "aws_organizations_policy" "require_s3_sse" {
  name        = "RequireS3SSE"
  description = "Requires all S3 PutObject calls to include a server-side encryption header (SSE-KMS or SSE-S3). Enforces encryption of data at rest in S3 across all workload accounts."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.require_s3_sse.json
}

# Apply to workload accounts (production and non-prod)
resource "aws_organizations_policy_attachment" "require_s3_sse_workloads" {
  policy_id = aws_organizations_policy.require_s3_sse.id
  target_id = local.workloads_ou_id
}

# Apply to security accounts (log archive, security tooling)
resource "aws_organizations_policy_attachment" "require_s3_sse_security" {
  policy_id = aws_organizations_policy.require_s3_sse.id
  target_id = local.security_ou_id
}

# Apply to infrastructure accounts (shared services)
resource "aws_organizations_policy_attachment" "require_s3_sse_infrastructure" {
  policy_id = aws_organizations_policy.require_s3_sse.id
  target_id = local.infrastructure_ou_id
}

###############################################################################
# SCP 6: DenyPublicS3ACLs
# Scope: Root
# WHY: Public S3 ACLs are a common source of data breaches. Even with
#      S3 Block Public Access enabled, ACLs can inadvertently grant public
#      access if BPA is misconfigured. This SCP prevents public-granting ACL
#      values from being applied to buckets or objects.
###############################################################################

data "aws_iam_policy_document" "deny_public_s3_acls" {
  statement {
    sid    = "DenyPublicS3ACLs"
    effect = "Deny"
    actions = [
      "s3:PutBucketAcl", # Bucket-level ACLs
      "s3:PutObjectAcl", # Object-level ACLs
    ]
    resources = [
      "arn:aws:s3:::*",
      "arn:aws:s3:::*/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values = [
        "public-read",        # Anyone can read
        "public-read-write",  # Anyone can read and write (catastrophic)
        "authenticated-read", # Any AWS-authenticated user can read
      ]
    }
  }
}

resource "aws_organizations_policy" "deny_public_s3_acls" {
  name        = "DenyPublicS3ACLs"
  description = "Prevents setting public-read, public-read-write, or authenticated-read ACLs on S3 buckets or objects. Complements S3 Block Public Access."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_public_s3_acls.json
}

resource "aws_organizations_policy_attachment" "deny_public_s3_acls_root" {
  policy_id = aws_organizations_policy.deny_public_s3_acls.id
  target_id = local.org_root_id
}

###############################################################################
# SCP 7: DenyPublicS3Buckets
# Scope: Root
# WHY: S3 Block Public Access (BPA) is the primary control against public S3
#      buckets. This SCP ensures BPA cannot be disabled at either the account
#      or bucket level by any principal, including account administrators.
#      Works in concert with SCP 6 (ACL controls) for defense in depth.
###############################################################################

data "aws_iam_policy_document" "deny_public_s3_buckets" {
  # Deny disabling Block Public Access at the account level
  statement {
    sid    = "DenyDisablingAccountBPA"
    effect = "Deny"
    actions = [
      "s3:PutAccountPublicAccessBlock",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "s3:PublicAccessBlockConfiguration.BlockPublicAcls"
      values   = ["false"]
    }
  }

  # Deny disabling Block Public Access at the bucket level
  statement {
    sid    = "DenyDisablingBucketBPA"
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

resource "aws_organizations_policy" "deny_public_s3_buckets" {
  name        = "DenyPublicS3Buckets"
  description = "Prevents disabling S3 Block Public Access at the account or bucket level. No S3 bucket in this organisation should ever be publicly accessible."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.deny_public_s3_buckets.json
}

resource "aws_organizations_policy_attachment" "deny_public_s3_buckets_root" {
  policy_id = aws_organizations_policy.deny_public_s3_buckets.id
  target_id = local.org_root_id
}

###############################################################################
# SCP 8: RequireMFAForConsoleLogin
# Scope: Root
# WHY: IAM users who authenticate with only a password (no MFA) have a
#      permanent credential that, if phished or leaked, grants persistent access.
#      This SCP forces any IAM user session without MFA to be limited to only
#      the actions needed to register an MFA device, preventing any damage
#      from a compromised password.
#
# NOTE: In an Identity Center-only environment, this is defence-in-depth for
#       legacy IAM users. If your org has zero IAM users, this SCP is still
#       worth retaining as a guardrail against future IAM user creation.
###############################################################################

data "aws_iam_policy_document" "require_mfa_for_console" {
  statement {
    sid    = "DenyWithoutMFA"
    effect = "Deny"

    # Exempt the minimum actions needed to register an MFA device.
    # Without these exemptions, a user without MFA cannot log in and
    # register a device — creating a lockout situation.
    not_actions = [
      "iam:CreateVirtualMFADevice",
      "iam:EnableMFADevice",
      "iam:GetUser",
      "iam:ListMFADevices",
      "iam:ListVirtualMFADevices",
      "iam:ResyncMFADevice",
      "sts:GetSessionToken",
    ]

    resources = ["*"]

    condition {
      test     = "BoolIfExists"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["false"]
    }

    # Exempt service-to-service calls that arrive via AWS services
    # (e.g., CloudFormation deploying on your behalf). These calls do not
    # have MFA context and should not be blocked.
    condition {
      test     = "Bool"
      variable = "aws:ViaAWSService"
      values   = ["false"]
    }
  }
}

resource "aws_organizations_policy" "require_mfa_for_console" {
  name        = "RequireMFAForConsoleLogin"
  description = "Denies all actions for IAM user sessions that do not have MFA active. Prevents damage from phished passwords. Exempts MFA device registration and service-to-service calls."
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.require_mfa_for_console.json
}

resource "aws_organizations_policy_attachment" "require_mfa_for_console_root" {
  policy_id = aws_organizations_policy.require_mfa_for_console.id
  target_id = local.org_root_id
}
