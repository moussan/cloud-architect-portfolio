# IAM — Enterprise Identity & Access Management

> **Why IAM is the hardest part of AWS.**
> Anyone can provision infrastructure. Defining who can do what, across how many accounts, without blocking legitimate work or leaving gaps an attacker can walk through — that is the hard part. IAM mistakes are the leading cause of AWS security incidents. This document explains the patterns that work at enterprise scale.

---

## IAM Identity Center Architecture

[AWS IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html) (formerly AWS SSO) is the correct solution for human access to AWS in any multi-account environment. It is not just a convenience feature — it is a security control.

### Architecture Overview

```
  Corporate IdP (Azure AD / Okta / Google Workspace)
         │
         │  SAML 2.0 or OIDC federation
         ▼
  ┌─────────────────────────────┐
  │   IAM Identity Center       │
  │   (Management Account)      │
  │                             │
  │  ┌─────────────────────┐   │
  │  │   Identity Source   │   │
  │  │ (External IdP / SSO │   │
  │  │  store / AD)        │   │
  │  └─────────────────────┘   │
  │                             │
  │  ┌─────────────────────┐   │
  │  │   Permission Sets   │   │
  │  │  AdministratorAccess│   │
  │  │  PowerUserAccess    │   │
  │  │  ReadOnlyAccess     │   │
  │  │  ...                │   │
  │  └─────────────────────┘   │
  │                             │
  │  ┌─────────────────────┐   │
  │  │   Assignments       │   │
  │  │  Group → PermSet    │   │
  │  │         → Account   │   │
  │  └─────────────────────┘   │
  └─────────────────────────────┘
         │
         │  Generates short-lived STS credentials
         ▼
  ┌──────────┐  ┌──────────┐  ┌──────────┐
  │ Account A│  │ Account B│  │ Account C│
  │ IAM Role │  │ IAM Role │  │ IAM Role │
  │ (auto)   │  │ (auto)   │  │ (auto)   │
  └──────────┘  └──────────┘  └──────────┘
```

Identity Center creates an IAM role in each target account for each Permission Set assignment. When a user authenticates, they select an account and role from the portal; Identity Center issues short-lived STS credentials for that role. No long-lived access keys involved.

---

## Permission Sets Design Patterns

A Permission Set is the Identity Center abstraction for "what a user can do in a target account." It consists of:
- An AWS managed policy (e.g., `ReadOnlyAccess`) and/or
- A customer-managed inline policy scoped to the permission set
- A session duration (1–12 hours)

### Recommended Permission Set Catalogue

| Permission Set | Managed Policy | Custom Policy | Assigned To | Session |
|---------------|----------------|--------------|-------------|---------|
| `AdministratorAccess` | AdministratorAccess | MFA condition required | Platform team only | 1 hour |
| `PowerUserAccess` | PowerUserAccess | — | App team leads | 4 hours |
| `ReadOnlyAccess` | ReadOnlyAccess | — | All developers | 8 hours |
| `BillingAccess` | Billing | — | Finance team | 8 hours |
| `NetworkAdministratorAccess` | NetworkAdministrator | — | Network team | 4 hours |
| `SecurityAuditAccess` | SecurityAudit | — | Security/compliance | 8 hours |
| `DatabaseAdministratorAccess` | DatabaseAdministrator | — | DBA team | 4 hours |
| `DeploymentAccess` | Custom (ECR push, ECS deploy) | Custom | CI/CD service accounts | N/A (use OIDC) |

> **Why not just use `AdministratorAccess` for everyone?** Because the blast radius of a phished account scales with the permissions that account has. A developer with ReadOnlyAccess cannot delete production databases. The cost of over-permissioning is measured in incident response hours.

### MFA Condition for Elevated Access

Attach this inline policy to the `AdministratorAccess` permission set to require MFA:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyWithoutMFA",
      "Effect": "Deny",
      "NotAction": [
        "iam:CreateVirtualMFADevice",
        "iam:EnableMFADevice",
        "iam:GetUser",
        "iam:ListMFADevices",
        "iam:ListVirtualMFADevices",
        "iam:ResyncMFADevice",
        "sts:GetSessionToken"
      ],
      "Resource": "*",
      "Condition": {
        "BoolIfExists": {
          "aws:MultiFactorAuthPresent": "false"
        }
      }
    }
  ]
}
```

---

## Role Chaining and Trust Policies

### Role Chaining

Role chaining is when a role assumes another role. This is useful for cross-account access where the initiating principal is already an assumed role:

```
Developer → assumes AdministratorAccess in Management Account
                → assumes TerraformExecutionRole in Prod Account
                   → assumes DatabaseAdminRole in RDS account
```

**Caution:** Role chaining caps the maximum session duration at 1 hour regardless of either role's `MaxSessionDuration`. Plan for this in CI/CD pipelines with long-running operations.

### Trust Policy Patterns

#### Pattern 1: Cross-Account Role Assumption (from a specific account)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::MANAGEMENT-ACCOUNT-ID:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "Bool": {
          "aws:MultiFactorAuthPresent": "true"
        },
        "StringEquals": {
          "sts:ExternalId": "unique-external-id-per-account"
        }
      }
    }
  ]
}
```

#### Pattern 2: Service Role (EC2 instance profile)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

#### Pattern 3: OIDC Federation (GitHub Actions)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT-ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:moussan/cloud-architect-portfolio:*"
        }
      }
    }
  ]
}
```

> **Why OIDC for CI/CD instead of long-lived access keys?** OIDC eliminates secrets management for CI/CD entirely. GitHub Actions gets a short-lived token scoped to the specific workflow, repo, and branch. There is no secret to rotate, leak, or manage. This pattern applies to any OIDC-capable CI/CD system (GitLab, CircleCI, etc.).

---

## Service-Linked Roles vs. Customer-Managed Roles

| Aspect | Service-Linked Role | Customer-Managed Role |
|--------|--------------------|-----------------------|
| **Created by** | AWS, when you enable a service | You, via IAM or Terraform |
| **Trust policy** | Fixed — only the AWS service can assume it | You define who can assume it |
| **Permission policy** | AWS-managed, may be updated by AWS | You own and maintain it |
| **Can be deleted** | Only after the service is disabled/no resources exist | Anytime |
| **When to use** | Always — let AWS manage the service-specific role | Custom automation, cross-account access, least-privilege service roles |

Common service-linked roles:
- `AWSServiceRoleForOrganizations` — created when you enable AWS Organizations
- `AWSServiceRoleForAmazonGuardDuty` — created when GuardDuty is enabled
- `AWSServiceRoleForEC2Spot` — created when Spot Instances are used

---

## IAM Access Analyzer

[IAM Access Analyzer](https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html) continuously monitors resource-based policies across your accounts and identifies resources that are shared externally (accessible from outside your account or organisation).

### What It Analyzes

| Resource Type | What it detects |
|---------------|----------------|
| S3 buckets | Bucket policies allowing public or cross-account access |
| IAM roles | Trust policies allowing external principals |
| KMS keys | Key policies allowing external access |
| Lambda functions | Resource-based policies allowing external invocation |
| SQS queues | Queue policies allowing external access |
| Secrets Manager secrets | Resource policies allowing external access |

### Organisation-Level Analyzer

An organisation-level analyzer (set up in the [security tooling account](../landing-zone/)) uses the organisation as the zone of trust. Resources shared within the organisation are **not** flagged as findings — only genuinely external access is reported. This drastically reduces false positives compared to account-level analyzers.

```hcl
resource "aws_accessanalyzer_analyzer" "org_level" {
  analyzer_name = "org-level-analyzer"
  type          = "ORGANIZATION"  # Requires delegated admin setup
}
```

---

## Resource-Based vs. Identity-Based Policies

| Policy Type | Where it lives | Controls |
|------------|----------------|----------|
| **Identity-based** | Attached to IAM user, group, or role | What the identity can do |
| **Resource-based** | Attached to the resource (S3 bucket, KMS key, SQS queue, etc.) | Who can access the resource |

### Cross-Account Access: Two Patterns

#### Pattern 1: Resource Policy (no role assumption required)

The resource in Account B has a policy that allows a principal from Account A:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::ACCOUNT-A-ID:role/cross-account-reader"
      },
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::my-bucket/*"
    }
  ]
}
```

The principal in Account A also needs an identity-based policy allowing `s3:GetObject` on the resource. Both policies must allow the action.

#### Pattern 2: AssumeRole (role assumption in the target account)

Account A principal assumes a role in Account B, then uses Account B's IAM context. More flexible — the assumed role can have broad permissions within Account B. Requires a trust policy on the role and an `sts:AssumeRole` permission on the assuming principal.

> **When to use resource policies vs. AssumeRole?** Use resource policies for simple, specific cross-account access (read this S3 bucket, send to this SQS queue). Use AssumeRole when the cross-account principal needs to act as an identity within the target account with multiple permissions, or when you want centralized access logging that shows the assumed role's ARN.

---

## ❓ FAQ

### Q: Should I use IAM users or IAM Identity Center for human access?

**A:** IAM Identity Center for all human access. IAM users generate long-lived credentials that cannot be centrally revoked when an employee leaves, are frequently leaked, and require per-account management. Identity Center provides short-lived credentials, central deprovisioning (remove the user from the IdP, access disappears from all accounts), and a full audit trail.

### Q: What is the difference between a Permission Boundary and an SCP?

**A:** An SCP is applied at the AWS account or OU level by the management account — it cannot be modified by anyone in the member account. A Permission Boundary is applied to a specific IAM role or user within an account — it can be set by any IAM administrator in that account. SCPs are cross-account enforcement; Permission Boundaries are intra-account delegation controls (e.g., "this role can only create other roles that have this Permission Boundary attached").

### Q: Can I use IAM roles to replace IAM users entirely?

**A:** Yes, and you should. IAM users should not exist in production accounts in 2024. Human access uses Identity Center. Service access uses IAM roles with instance profiles, OIDC federation, or service-linked roles. If you have a legacy use case that requires IAM users (e.g., an old third-party tool that only supports access keys), use Secrets Manager to rotate the credentials automatically.

### Q: How do I handle break-glass (emergency) access?

**A:** Create a `BreakGlassAdmin` IAM role in each account (or in the management account with cross-account trust). Store the credentials for assuming this role in AWS Secrets Manager with restricted access. Require MFA. Enable CloudTrail alerting on any use of this role. Rotate the MFA device and review access after each use. Document the process in a runbook.

### Q: What is the ExternalId condition and when should I use it?

**A:** `sts:ExternalId` in a trust policy is the "confused deputy" mitigation. When a third party (e.g., a SaaS vendor) assumes a role in your account, requiring an ExternalId that only you and the vendor know ensures that even if the vendor's AWS account is compromised, the attacker cannot assume your role without knowing the ExternalId. Use ExternalId in any trust policy where the trusted principal is not an account you own.

### Q: How do I find unused IAM roles and permissions?

**A:** Use [IAM Access Analyzer](https://docs.aws.amazon.com/IAM/latest/UserGuide/access-analyzer-policy-generation.html) policy generation to identify the minimum permissions a role actually used in the last 90 days. Also review the `aws_iam_last_used` attribute via the IAM API or [AWS IAM Access Advisor](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_access-advisor.html) to find policies and services that haven't been accessed. Unused permissions are attack surface.
