terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Root Organization
resource "aws_organizations_organization" "this" {
  feature_set = "ALL"
}

# Organizational Units
resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = aws_organizations_organization.this.roots[0].id
}

# Example accounts (note: email addresses must be unique/real)
resource "aws_organizations_account" "security_account" {
  name      = "SecurityAccount"
  email     = var.security_account_email
  parent_id = aws_organizations_organizational_unit.security.id
}

resource "aws_organizations_account" "prod_account" {
  name      = "ProdAccount"
  email     = var.prod_account_email
  parent_id = aws_organizations_organizational_unit.workloads.id
}

# Example SCP: Restrict to allowed regions
data "aws_iam_policy_document" "deny_non_allowed_regions" {
  statement {
    sid    = "DenyNonAllowedRegions"
    effect = "Deny"

    actions   = ["*"]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = var.allowed_regions
    }

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_organizations_policy" "deny_non_allowed_regions" {
  name    = "DenyNonAllowedRegions"
  type    = "SERVICE_CONTROL_POLICY"
  content = data.aws_iam_policy_document.deny_non_allowed_regions.json
}

resource "aws_organizations_policy_attachment" "workloads_ou_attachment" {
  policy_id = aws_organizations_policy.deny_non_allowed_regions.id
  target_id = aws_organizations_organizational_unit.workloads.id
}
