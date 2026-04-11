# Landing Zone — Terraform Module

> **Why a landing zone module?**
> A landing zone is not a one-time click-through wizard — it is a living, version-controlled definition of your AWS organisational structure. Expressing it in Terraform means every OU, account, SCP, and tag policy is in source control, reviewed via pull request, and reproducible from scratch. When AWS rolls out new account types or your organisation's compliance requirements change, you update code — not console state.

---

## What This Module Provisions

| Resource | Count | Purpose |
|----------|-------|---------|
| AWS Organisation | 1 | Root container with all features enabled |
| Organisational Units | 6 | Security, Infrastructure, Workloads, Prod, Non-Prod, Sandbox |
| Member Accounts | 7 | Log Archive, Security Tooling, Shared Services, Prod×2, Dev, Staging, Sandbox |
| Service Control Policies | 6 | Region lock, no-leave-org, IMDSv2, root actions deny, S3 encryption, public S3 deny |
| Tag Policy | 1 | Organisation-wide tag enforcement |
| SCP Attachments | 8 | SCPs applied to appropriate OUs |
| Policy Types Enabled | 3 | SERVICE_CONTROL_POLICY, TAG_POLICY, BACKUP_POLICY |

---

## Architecture Decisions

### Why S3 Backend?

Terraform state is the source of truth for your infrastructure. Storing it locally means:
- It cannot be shared across team members
- It is not encrypted at rest
- It can be lost if the developer's machine is lost
- Concurrent applies corrupt the state

S3 + DynamoDB backend solves all four problems: state is centralised, encrypted with SSE-KMS, protected from concurrent applies via DynamoDB locking, and access is controlled by IAM.

> **The backend S3 bucket and DynamoDB table must be created *before* running this module.** They cannot be created by the same Terraform that uses them as a backend. Provision them manually or with a separate `bootstrap/` Terraform configuration.

### Why All Features Enabled on the Organisation?

AWS Organisations supports two feature sets: `CONSOLIDATED_BILLING` and `ALL_FEATURES`. The consolidated billing mode only enables cost aggregation. `ALL_FEATURES` enables SCPs, tag policies, backup policies, and AI services opt-out policies. There is no reason to use consolidated billing only — enabling all features is a one-way door (you cannot go back), but it is the correct starting point for any enterprise.

### Why This Specific OU Structure?

See the [pillar-level governance README](../README.md#landing-zone-architecture) for the full rationale. In summary: the OU structure mirrors policy domains, not team structures. Teams own accounts; OUs own policy bands.

---

## Module Inputs

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `management_account_id` | `string` | Yes | — | AWS account ID of the management account |
| `management_account_email` | `string` | Yes | — | Email address for the management account |
| `org_feature_set` | `string` | No | `"ALL_FEATURES"` | Organisation feature set |
| `allowed_regions` | `list(string)` | No | `["ca-central-1", "us-east-1"]` | Regions permitted by the region-lock SCP |
| `log_archive_email` | `string` | Yes | — | Email for Log Archive account |
| `security_tooling_email` | `string` | Yes | — | Email for Security Tooling account |
| `shared_services_email` | `string` | Yes | — | Email for Shared Services account |
| `prod_app1_email` | `string` | Yes | — | Email for Prod App 1 account |
| `prod_app2_email` | `string` | Yes | — | Email for Prod App 2 account |
| `dev_email` | `string` | Yes | — | Email for Dev account |
| `staging_email` | `string` | Yes | — | Email for Staging account |
| `sandbox_email` | `string` | Yes | — | Email for Sandbox account |
| `default_tags` | `map(string)` | No | See variables.tf | Tags applied to all taggable resources |

---

## Module Outputs

| Output | Description |
|--------|-------------|
| `org_id` | AWS Organisation ID |
| `org_root_id` | Organisation root ID |
| `security_ou_id` | Security OU ID |
| `infrastructure_ou_id` | Infrastructure OU ID |
| `workloads_ou_id` | Workloads OU ID |
| `production_ou_id` | Production OU ID |
| `non_prod_ou_id` | Non-Prod OU ID |
| `sandbox_ou_id` | Sandbox OU ID |
| `log_archive_account_id` | Log Archive account ID |
| `security_tooling_account_id` | Security Tooling account ID |
| `shared_services_account_id` | Shared Services account ID |
| `prod_app1_account_id` | Prod App 1 account ID |
| `prod_app2_account_id` | Prod App 2 account ID |
| `dev_account_id` | Dev account ID |
| `staging_account_id` | Staging account ID |
| `sandbox_account_id` | Sandbox account ID |
| `scp_deny_non_allowed_regions_id` | SCP: DenyNonAllowedRegions |
| `scp_deny_leave_org_id` | SCP: DenyLeaveOrganization |
| `scp_require_imdsv2_id` | SCP: RequireIMDSv2 |
| `scp_deny_root_actions_id` | SCP: DenyRootAccountActions |
| `scp_require_s3_sse_id` | SCP: RequireS3SSE |
| `scp_deny_public_s3_id` | SCP: DenyPublicS3Buckets |

---

## Usage

### Minimum Configuration

```hcl
# main.tf in your environment directory

terraform {
  backend "s3" {
    bucket         = "my-org-terraform-state"
    key            = "landing-zone/terraform.tfstate"
    region         = "ca-central-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

module "landing_zone" {
  source = "github.com/moussan/cloud-architect-portfolio//01-governance/landing-zone/terraform"

  management_account_id    = "123456789012"
  management_account_email = "aws-management@example.com"
  log_archive_email        = "aws-log-archive@example.com"
  security_tooling_email   = "aws-security-tooling@example.com"
  shared_services_email    = "aws-shared-services@example.com"
  prod_app1_email          = "aws-prod-app1@example.com"
  prod_app2_email          = "aws-prod-app2@example.com"
  dev_email                = "aws-dev@example.com"
  staging_email            = "aws-staging@example.com"
  sandbox_email            = "aws-sandbox@example.com"

  allowed_regions = ["ca-central-1", "us-east-1"]
}
```

### Consuming Outputs in Other Modules

```hcl
# 02-networking/transit-gateway/main.tf
data "terraform_remote_state" "landing_zone" {
  backend = "s3"
  config = {
    bucket = "my-org-terraform-state"
    key    = "landing-zone/terraform.tfstate"
    region = "ca-central-1"
  }
}

resource "aws_ec2_transit_gateway" "main" {
  # Deploy into the shared services account
  provider = aws.shared_services
  # ...
}

provider "aws" {
  alias  = "shared_services"
  region = "ca-central-1"
  assume_role {
    role_arn = "arn:aws:iam::${data.terraform_remote_state.landing_zone.outputs.shared_services_account_id}:role/TerraformExecutionRole"
  }
}
```

---

## How to Extend This Module

### Adding a New Account

1. Add a new `variable` for the account email in `variables.tf`
2. Add an `aws_organizations_account` resource in `main.tf`
3. Move the account to the appropriate OU using `aws_organizations_account.parent_id`
4. Add the account ID to `outputs.tf`
5. Determine which existing SCPs apply and verify they are attached to the parent OU

### Adding a New OU

1. Add an `aws_organizations_organizational_unit` resource in `main.tf`
2. Set `parent_id` to the appropriate existing OU or root
3. Attach relevant SCPs to the new OU
4. Add the OU ID to `outputs.tf`

### Adding a New SCP

1. Add a new `aws_iam_policy_document` data source with the policy JSON in `main.tf`
2. Add a corresponding `aws_organizations_policy` resource
3. Add `aws_organizations_policy_attachment` resources for each target OU
4. Add the SCP ID to `outputs.tf`
5. Document the SCP in [`../scps/README.md`](../scps/README.md) with full explanation

> **Test SCPs safely.** Before attaching a new SCP to a production OU, attach it to the Sandbox OU and verify that intended traffic is denied and legitimate traffic is not blocked. See the [SCPs README](../scps/README.md#testing-scps-safely) for the full testing procedure.
