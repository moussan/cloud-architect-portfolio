# Infrastructure as Code (IaC) Pillar

> **Pillar owner:** Moussa El Najmi — Senior AWS Solutions Architect  
> **Toolchain:** Terraform ≥ 1.5, AWS Provider ≥ 5.x, tfsec, checkov, terraform-docs  
> **Status:** Production-ready reference implementations

---

## Table of Contents

1. [Overview](#overview)
2. [Project Structure](#project-structure)
3. [Terraform Best Practices](#terraform-best-practices)
4. [State Management](#state-management)
5. [Terragrunt — Optional Layer](#terragrunt--optional-layer)
6. [CI/CD for Terraform](#cicd-for-terraform)
7. [FAQ](#-faq)
8. [AWS Documentation Links](#aws-documentation-links)

---

## Overview

### Why IaC is non-negotiable at enterprise scale

Manual infrastructure provisioning through the AWS Console is a liability, not a workflow. At enterprise scale it introduces:

| Problem | Consequence |
|---|---|
| **Configuration drift** | Console clicks produce undocumented snowflake resources. Two environments diverge within weeks. |
| **No audit trail** | You cannot answer "who changed this security group on what date?" |
| **No repeatability** | Recreating an environment after an incident takes days, not minutes. |
| **Error-prone handoffs** | Runbooks written in Confluence rot. Code in Git doesn't. |
| **Compliance gaps** | SOC 2, PCI DSS, and ISO 27001 require demonstrable control over configuration changes. |

Terraform solves all five with a single workflow: **declare the desired state, plan the diff, apply atomically, review in Git**.

### What this pillar demonstrates

This pillar is a portfolio of production-quality Terraform that a senior AWS architect would ship to a real enterprise customer. It covers:

- **State backend bootstrapping** — the one chicken-and-egg problem every team encounters
- **Compute** — EC2 Launch Templates, Auto Scaling Groups with mixed Spot/On-Demand, ALB
- **Storage** — S3 with KMS CMK, Object Lock, replication, lifecycle policies
- **Database** — Aurora Serverless v2, RDS Proxy, Secrets Manager rotation
- **Reusable modules** — IAM role factory with OIDC, EC2 instance profile, cross-account assume role

Every resource is production-hardened: encryption at rest, encryption in transit, least-privilege IAM, security group lockdown, observability hooks.

---

## Project Structure

```
03-iac/
├── modules/                    # Reusable building blocks (consumed via git tag or registry)
│   ├── vpc/                    # VPC, subnets, route tables, NAT GW, VPC endpoints
│   ├── ec2-asg/                # Launch Template + ASG + ALB (opinionated)
│   ├── rds/                    # Aurora cluster + proxy + Secrets Manager
│   ├── s3/                     # Hardened S3 bucket with KMS, versioning, lifecycle
│   └── iam-role/               # IAM role factory: EC2, Lambda, cross-account, OIDC
├── compute/                    # Standalone compute root module (reference implementation)
│   ├── README.md
│   └── terraform/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
├── storage/                    # S3 reference implementation
│   ├── README.md
│   └── terraform/
│       └── main.tf
├── database/                   # Aurora Serverless v2 reference implementation
│   ├── README.md
│   └── terraform/
│       └── main.tf
└── state-backend/              # Must be provisioned first — bootstraps all other state
    ├── README.md
    └── terraform/
        └── main.tf
```

> **Why this layout and not workspaces?**  
> Each top-level directory is an independent Terraform root module with its own `terraform.tfstate`. This is the directory-based environment pattern — detailed in [Best Practices](#workspace-vs-directory-based-environments) below.

---

## Terraform Best Practices

### Remote State (S3 + DynamoDB Locking)

Every root module stores state in S3 with DynamoDB locking. The backend block looks like:

```hcl
terraform {
  backend "s3" {
    bucket         = "myorg-tfstate-prod"
    key            = "compute/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "myorg-tfstate-lock"
    kms_key_id     = "alias/myorg-tfstate"
  }
}
```

See [State Management](#state-management) for the full breakdown.

### Workspace vs Directory-Based Environments

> **Why directory-based wins:**  
> Terraform workspaces share a single backend configuration and module version. A `terraform workspace select prod && terraform destroy` destroys production. With directory-based environments, `prod/` and `staging/` have separate state files, separate variable files, and separate IAM policies. Blast radius is bounded by design.

The workspace pattern is appropriate only for short-lived feature branches on stateless infrastructure (e.g., ephemeral review environments). It is not appropriate for long-lived environments (dev/staging/prod).

| | Workspaces | Directory-based |
|---|---|---|
| State isolation | Shared backend, different keys | Separate backends possible |
| IAM blast radius | Same credentials touch all envs | Different roles per directory |
| Refactoring risk | High — one wrong command | Low — explicit path required |
| Tooling required | None | Terragrunt (optional) |
| Recommended for | Ephemeral review envs | All long-lived environments |

### Module Versioning Strategy

Modules are pinned by Git tag in the `source` argument:

```hcl
module "vpc" {
  source  = "git::https://github.com/myorg/terraform-modules.git//vpc?ref=v2.3.1"
  # Never use ?ref=main — main moves and your plan output changes
}
```

Semantic versioning: `MAJOR.MINOR.PATCH`
- **PATCH** — bug fix, no interface change
- **MINOR** — new optional variable, backward-compatible
- **MAJOR** — breaking change to inputs/outputs

> **Why pin by tag, not branch?**  
> A branch ref is mutable. If a teammate merges to `main` while your CI pipeline is running a plan, your apply might use different code than your plan. Tags are immutable.

### Variable Validation Blocks

Validation blocks catch misconfiguration before Terraform makes a single API call:

```hcl
variable "environment" {
  type        = string
  description = "Deployment environment. Controls instance sizing, retention, and deletion protection."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "instance_type" {
  type        = string

  validation {
    condition     = !(var.environment == "prod" && startswith(var.instance_type, "t2."))
    error_message = "t2 instance types are burstable and not allowed in prod. Use m6i or c6i family."
  }
}
```

### Precondition / Postcondition Checks (Terraform 1.2+)

Lifecycle preconditions guard against logical errors that variable validation cannot catch (e.g., cross-resource constraints):

```hcl
resource "aws_db_instance" "main" {
  # ...

  lifecycle {
    precondition {
      condition     = var.environment == "prod" ? var.backup_retention_period >= 7 : true
      error_message = "Production databases must retain backups for at least 7 days."
    }

    postcondition {
      condition     = self.multi_az == true || var.environment != "prod"
      error_message = "Production RDS instances must be Multi-AZ."
    }
  }
}
```

### Moved Blocks for Safe Refactoring

When you rename or reorganize resources, a `moved` block prevents Terraform from destroying and recreating:

```hcl
# Renamed aws_security_group.app → aws_security_group.application_tier
moved {
  from = aws_security_group.app
  to   = aws_security_group.application_tier
}
```

This is preferable to `terraform state mv` for team workflows because the intent is peer-reviewed in Git.

### Import Blocks (Terraform 1.5+)

Bring existing unmanaged infrastructure under Terraform control without manual `terraform import` commands:

```hcl
import {
  to = aws_s3_bucket.legacy_app_data
  id = "my-legacy-bucket-name"
}
```

Run `terraform plan -generate-config-out=generated.tf` to auto-generate the resource block, then review and commit.

### Sensitive Variable Handling

Never hardcode secrets. The pattern of record:

1. **Secrets Manager or Parameter Store** — store the secret there
2. **Data source at runtime** — Terraform reads it with `aws_secretsmanager_secret_version`
3. **Mark outputs sensitive** — `sensitive = true` prevents logging

```hcl
data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db.id
}

# Mark the output so it never appears in plan/apply output
output "db_password" {
  value     = data.aws_secretsmanager_secret_version.db_password.secret_string
  sensitive = true
}
```

Never pass secrets via `-var` on the CLI or store them in `.tfvars` files committed to Git. Use `.gitignore` to exclude `*.tfvars` files that contain real values.

### Provider Version Pinning

```hcl
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.30"  # allows 5.30.x but not 6.x
    }
  }
}
```

> **Why pin the provider version?**  
> AWS provider minor releases occasionally change plan output or require resource recreation for existing resources. A `version = ">= 3.0"` constraint can pull in breaking changes on the next `terraform init -upgrade`. Pin to a `~>` constraint and upgrade deliberately.

---

## State Management

### Why Remote State is Essential

Local state (`terraform.tfstate` on a developer's laptop) is incompatible with team workflows:

- Two engineers running `terraform apply` simultaneously will corrupt state
- The state file contains secrets — it must never live in Git
- Recovery after laptop loss is impossible

Remote state in S3 provides versioning, encryption, and DynamoDB locking to prevent concurrent writes.

### S3 Bucket Hardening for State

The state bucket requires every security control enabled:

| Control | Why |
|---|---|
| **Versioning** | State corruption recovery — roll back to any prior version |
| **MFA Delete** | Prevents accidental or malicious version deletion without a hardware MFA token |
| **Server-Side Encryption (KMS)** | State files contain passwords, private keys, and resource IDs — treat them as secrets |
| **Block All Public Access** | No scenario where state should be publicly readable |
| **Access Logging** | Audit trail — who accessed the state file and when |
| **Bucket Policy — deny non-TLS** | Prevent credentials being leaked over HTTP |
| **Lifecycle — retain 90 days** | Enough history to recover from any incident without unbounded storage cost |

### DynamoDB Locking Table

```
Table name: myorg-tfstate-lock
Hash key:   LockID (String)
Billing:    PAY_PER_REQUEST
PITR:       Enabled
```

When Terraform runs, it writes a lock item: `{"LockID": "myorg-tfstate-prod/compute/terraform.tfstate"}`. Any concurrent apply finds the lock item and aborts. The item is deleted when the operation completes.

> **Why PAY_PER_REQUEST?**  
> Lock operations are bursty — multiple pipelines at deployment time, then nothing for hours. Provisioned capacity requires capacity planning for a table that may receive one write per hour. On-demand billing is cheaper and requires zero maintenance.

### State File Isolation Strategies

**One state file per environment per module** is the recommended pattern:

```
s3://myorg-tfstate/
├── dev/
│   ├── compute/terraform.tfstate
│   ├── database/terraform.tfstate
│   └── storage/terraform.tfstate
├── staging/
│   ├── compute/terraform.tfstate
│   └── ...
└── prod/
    ├── compute/terraform.tfstate
    └── ...
```

This limits the blast radius of any single `terraform apply`: a mistake in `compute/` cannot affect `database/` state.

**Cross-module dependencies** are resolved via `terraform_remote_state` data source or (preferred) by passing ARNs as input variables:

```hcl
# Preferred: explicit input variable — no hidden coupling
variable "vpc_id" {
  type        = string
  description = "VPC ID from the networking root module outputs."
}
```

### State File Recovery Procedures

**Scenario 1 — Corrupted state (bad apply mid-run):**
1. `aws s3api list-object-versions --bucket myorg-tfstate --prefix compute/terraform.tfstate`
2. Identify the last known-good version ID
3. `aws s3api get-object --bucket myorg-tfstate --key compute/terraform.tfstate --version-id <id> terraform.tfstate.backup`
4. `terraform state push terraform.tfstate.backup`

**Scenario 2 — State drift (someone made console changes):**
1. Run `terraform plan` — it will show the drift as changes Terraform wants to make
2. Option A: Let Terraform reconcile (apply the plan — puts it back to declared state)
3. Option B: Import the drift — add `import {}` blocks to adopt the change into code

**Scenario 3 — Orphaned lock (pipeline crashed mid-apply):**
1. `terraform force-unlock <lock-id>` — the lock ID is in the DynamoDB item
2. Verify the prior apply's CloudTrail events before re-running

---

## Terragrunt — Optional Layer

[Terragrunt](https://terragrunt.gruntwork.io/) is a thin wrapper around Terraform that solves two real problems at scale:

### 1. DRY Configurations

Without Terragrunt, every root module repeats the same backend block with slightly different paths. With Terragrunt:

```hcl
# terragrunt.hcl (root)
remote_state {
  backend = "s3"
  config = {
    bucket         = "myorg-tfstate-${local.account_id}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "myorg-tfstate-lock"
  }
}
```

Every child module inherits this configuration without duplication.

### 2. Dependency Management Between Modules

```hcl
# database/terragrunt.hcl
dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    private_subnet_ids = ["subnet-00000000", "subnet-11111111"]
  }
}

inputs = {
  subnet_ids = dependency.vpc.outputs.private_subnet_ids
}
```

Terragrunt reads the VPC outputs and passes them as inputs to the database module — no manual copying of values, no `terraform_remote_state` coupling.

### 3. Environment Promotion Workflow

```
environments/
├── dev/
│   ├── vpc/terragrunt.hcl
│   ├── compute/terragrunt.hcl
│   └── database/terragrunt.hcl
├── staging/
│   └── ...       # Same structure, different inputs
└── prod/
    └── ...
```

`terragrunt run-all plan --terragrunt-working-dir environments/prod` plans every module in dependency order. No manual sequencing.

> **When to add Terragrunt:**  
> Add it when you have ≥3 environments and ≥5 root modules. Before that point, the operational overhead exceeds the benefit. A single team with one environment does not need Terragrunt.

---

## CI/CD for Terraform

### Pipeline Design Principles

1. **Plans are artifacts** — store them, don't recompute on apply
2. **Never auto-apply to production** — require human approval
3. **Static analysis before plan** — fail fast, cheaply

### Full Pipeline Workflow

#### Step 1 — Pull Request Opened

```yaml
# .github/workflows/terraform-pr.yml
on:
  pull_request:
    paths: ['03-iac/**']

jobs:
  static-analysis:
    steps:
      - uses: actions/checkout@v4

      - name: terraform fmt check
        run: terraform fmt -check -recursive
        # Fails if any file is not canonical format.
        # Enforces consistent style without a style guide document.

      - name: terraform validate
        run: |
          terraform init -backend=false
          terraform validate
        # Catches type errors, missing required arguments, invalid references.
        # -backend=false skips S3 credentials — fast and runs without AWS access.

      - name: tfsec
        uses: aquasecurity/tfsec-action@v1
        # Scans for known security misconfigurations:
        # - S3 buckets with public access enabled
        # - Security groups open to 0.0.0.0/0 on sensitive ports
        # - RDS instances without encryption
        # - IAM policies with wildcard actions

      - name: checkov
        uses: bridgecrewio/checkov-action@v12
        with:
          framework: terraform
        # Broader policy library than tfsec.
        # Checks CIS Benchmarks, NIST, PCI DSS, HIPAA controls.
        # Runs against the Terraform plan JSON for highest accuracy.
```

#### Step 2 — PR Approved → Generate Plan

```yaml
  plan:
    needs: static-analysis
    environment: staging   # uses OIDC role for staging
    steps:
      - name: terraform plan
        run: |
          terraform init
          terraform plan -out=tfplan.binary
          terraform show -json tfplan.binary > tfplan.json

      - name: upload plan artifact
        uses: actions/upload-artifact@v4
        with:
          name: tfplan-${{ github.sha }}
          path: tfplan.binary
          retention-days: 7
        # Store the binary plan. Apply will use THIS exact plan —
        # not recompute it. Guarantees what you reviewed is what runs.
```

#### Step 3 — Merge to Main → Apply (with Gate)

```yaml
  apply:
    needs: plan
    environment: production   # requires manual approval in GitHub Environments settings
    steps:
      - name: download plan artifact
        uses: actions/download-artifact@v4
        with:
          name: tfplan-${{ github.sha }}

      - name: terraform apply
        run: terraform apply tfplan.binary
        # Applies exactly the plan that was reviewed.
        # GitHub's environment protection rules require a named reviewer
        # to approve before this step runs.
```

### OIDC Authentication (No Long-Lived Keys)

```hcl
# In the IAM module — see modules/iam-role/main.tf
# GitHub Actions assumes a role via OIDC — no AWS_ACCESS_KEY_ID in secrets
resource "aws_iam_role" "github_actions_terraform" {
  name = "github-actions-terraform-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:myorg/myrepo:*"
        }
      }
    }]
  })
}
```

> **Why OIDC instead of IAM user keys?**  
> IAM user access keys are long-lived credentials. A leaked key gives an attacker persistent access. OIDC tokens are short-lived (15 minutes), scoped to a specific GitHub repo, and require no rotation.

---

## ❓ FAQ

**Q: When should I use a module vs inline resource?**

A: Use a module when the same resource pattern is deployed in two or more places. The threshold is two, not three — duplication is where drift starts. A single S3 bucket for a one-off use case is fine inline. A pattern like "encrypted S3 bucket with versioning and access logging" that every team needs is a module. Modules also enforce org standards: if the only way to create an S3 bucket is through the `s3` module, and that module always enables encryption, you cannot accidentally create an unencrypted bucket.

---

**Q: How do I handle secrets in Terraform?**

A: Three rules:
1. **Never put secrets in `.tf` files or `.tfvars` files committed to Git.**
2. **Create the secret shell in Terraform** (the `aws_secretsmanager_secret` resource), then populate it out-of-band (via the console, CLI, or a separate pipeline that has access to the secret value).
3. **Reference secrets at runtime** via `data "aws_secretsmanager_secret_version"` — Terraform reads the current value when it runs but never stores the plaintext in the plan output (use `sensitive = true`).

For database passwords specifically, use Secrets Manager rotation with the `aws_secretsmanager_secret_rotation` resource so the password rotates automatically without a Terraform run.

---

**Q: What's the risk of terraform destroy?**

A: `terraform destroy` deletes **every resource in the state file** — databases, S3 buckets (if `force_destroy = true`), load balancers. In production this is catastrophic. Mitigations:

1. Set `deletion_protection = true` on RDS, Aurora, and any stateful resource. Terraform will fail before deleting them.
2. Use `prevent_destroy = true` in lifecycle blocks on critical resources.
3. Restrict IAM permissions for the Terraform role — it should not have `rds:DeleteDBCluster` in production.
4. Require a second human approval before any `terraform destroy` in CI.
5. S3 bucket versioning and object lock prevent data loss even if the bucket resource is deleted.

---

**Q: How do I import existing resources?**

A: Terraform 1.5+ `import` blocks are the recommended approach:

```hcl
import {
  to = aws_security_group.app
  id = "sg-0abc1234def56789"
}
```

Run `terraform plan -generate-config-out=generated.tf` to auto-generate the HCL. Review it carefully — generated code often has hard-coded values that should become variables. Then run `terraform apply` to record the import in state. Delete the `import` block after the first apply (it is idempotent but confusing to leave in).

For large-scale imports of many existing resources, consider [Terraformer](https://github.com/GoogleCloudPlatform/terraformer) or the AWS provider's `aws2tf` tooling as a starting point.

---

**Q: Should I use workspaces or separate directories for environments?**

A: Separate directories for long-lived environments (dev/staging/prod). See the detailed comparison in [Best Practices](#workspace-vs-directory-based-environments). The short answer: workspaces share module code and backend config — a typo in the wrong workspace is a prod outage. Directories are separate invocations that cannot interfere with each other.

---

**Q: How do I handle Terraform state drift?**

A: State drift means the real AWS infrastructure diverged from what Terraform's state file records — usually from console changes or manual AWS CLI commands.

**Detect:** `terraform plan` always shows drift. Make it a habit to run plan regularly, not just before applies.

**Reconcile options:**
1. **Apply the plan** — Terraform reverts the drift. Use this when the drift was unintentional.
2. **Update the code** — If the drift was intentional (someone fixed a production incident manually), codify the change and import the new configuration.
3. **terraform refresh** (deprecated in favour of `terraform apply -refresh-only`) — Updates the state file to match actual infrastructure without making changes. Use this to acknowledge drift before deciding what to do with it.

**Prevent drift:** Use SCPs (Service Control Policies) in AWS Organizations to deny console changes to infrastructure-owned resources. Tag all Terraform-managed resources with `managed_by = "terraform"` and alert on any change to a tagged resource that did not originate from the CI pipeline.

---

**Q: What is the Terraform lock file and should I commit it?**

A: The `.terraform.lock.hcl` file records the exact version and checksums of every provider used in the last `terraform init`. Yes, commit it. This guarantees every team member and every CI run uses identical provider binaries — without it, `terraform init` might download a different patch version that behaves differently.

```
# .gitignore — what NOT to commit
.terraform/          # downloaded provider binaries — never commit
*.tfstate            # state files — never commit
*.tfstate.backup
*.tfvars             # variable files with real values — never commit

# What to commit
.terraform.lock.hcl  # provider checksums — always commit
```

---

**Q: How do I structure a multi-account Terraform setup?**

A: The AWS Organizations pattern with one Terraform role per account:

```
accounts/
├── management/      # AWS Organizations, SCPs, CloudTrail org trail
├── security/        # GuardDuty delegated admin, Security Hub, centralized logging
├── shared-services/ # Transit Gateway, Route 53 resolver, ECR
├── dev/
│   ├── compute/
│   └── database/
├── staging/
└── prod/
```

Each directory has its own backend configuration pointing to a state bucket in that account. The Terraform CI role in `dev/` has permissions only in the dev account — it cannot touch prod resources. Account IDs are passed as variables; provider aliases handle cross-account resource creation (e.g., sharing a Route 53 zone):

```hcl
provider "aws" {
  alias  = "security"
  assume_role {
    role_arn = "arn:aws:iam::${var.security_account_id}:role/TerraformCrossAccount"
  }
}
```

---

**Q: What tools should I run in CI before terraform apply?**

A: In order:

| Tool | Purpose | Fail on? |
|---|---|---|
| `terraform fmt -check` | Canonical formatting | Yes |
| `terraform validate` | Syntax and type errors | Yes |
| `tfsec` | Security misconfigurations | Yes (on HIGH/CRITICAL) |
| `checkov` | CIS/NIST/PCI policy compliance | Yes (configurable) |
| `terraform plan -detailed-exitcode` | Shows intended changes | Store as artifact |
| `infracost` | Cost estimate for the plan | Comment on PR (don't fail) |
| OPA/Conftest | Custom org policy (e.g., no public IPs) | Yes |

Never run `terraform apply` without a stored plan artifact from the same commit.

---

**Q: How do I safely rename a Terraform resource?**

A: Use a `moved` block — do not use `terraform state mv` for team workflows (it requires manual execution and is not peer-reviewed).

```hcl
# In main.tf — rename aws_instance.web to aws_instance.web_server
moved {
  from = aws_instance.web
  to   = aws_instance.web_server
}

resource "aws_instance" "web_server" {
  # ... (was web)
}
```

The `moved` block tells Terraform the resource didn't change — only its address did. Terraform will update the state file entry rather than destroy and recreate. After the first successful apply, the `moved` block can be removed (though leaving it in does no harm and serves as documentation).

---

## AWS Documentation Links

- [Terraform AWS Provider Documentation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [AWS Well-Architected Framework — Operational Excellence](https://docs.aws.amazon.com/wellarchitected/latest/operational-excellence-pillar/welcome.html)
- [S3 Remote State Backend](https://developer.hashicorp.com/terraform/language/settings/backends/s3)
- [DynamoDB State Locking](https://developer.hashicorp.com/terraform/language/settings/backends/s3#dynamodb-state-locking)
- [Terraform Import (1.5+)](https://developer.hashicorp.com/terraform/language/import)
- [Terraform Moved Blocks](https://developer.hashicorp.com/terraform/language/modules/develop/refactoring)
- [Variable Validation](https://developer.hashicorp.com/terraform/language/values/variables#custom-validation-rules)
- [Preconditions and Postconditions](https://developer.hashicorp.com/terraform/language/expressions/custom-conditions)
- [AWS IAM OIDC Identity Providers](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)
- [Using GitHub Actions OIDC with AWS](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [AWS Service Control Policies](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html)
- [tfsec — Terraform Security Scanner](https://aquasecurity.github.io/tfsec/latest/)
- [Checkov — Infrastructure Policy as Code](https://www.checkov.io/1.Welcome/What%20is%20Checkov.html)
- [infracost — Cloud Cost Estimates](https://www.infracost.io/docs/)
