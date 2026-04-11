# Terraform Modules

> Reusable building blocks. Each module encapsulates a single AWS resource pattern with sensible defaults and escape hatches.

---

## Table of Contents

1. [Module Design Principles](#module-design-principles)
2. [Module Versioning](#module-versioning)
3. [Module Testing](#module-testing)
4. [Module Documentation](#module-documentation)
5. [Available Modules](#available-modules)

---

## Module Design Principles

### 1. Single Responsibility

Each module manages one logical unit of infrastructure. The `iam-role` module creates an IAM role. It does not also create an S3 bucket. If a pattern requires both, compose two modules.

Violation of this principle creates "god modules" — hundreds of variables, unexpected interactions between resources, and difficult debugging.

### 2. Sensible Defaults with Escape Hatches

A module should work for 80% of use cases with zero configuration beyond required inputs. The other 20% is handled by "escape hatches" — variables that override defaults.

```hcl
module "app_role" {
  source = "git::https://github.com/myorg/terraform-modules.git//iam-role?ref=v2.1.0"

  # Required inputs only
  role_name       = "my-app-role"
  trusted_service = "ec2.amazonaws.com"
  managed_policies = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"]

  # Default: no instance profile (most Lambda roles don't need one)
  # Escape hatch: create an instance profile for EC2 roles
  create_instance_profile = true
}
```

The module does not force you to specify everything. But if you need to, you can.

### 3. No Hidden Magic

Modules must not create resources the caller doesn't know about. Every resource a module creates should be either:
- Documented in the module's `README.md`
- Clearly named with the module's identifier
- Listed in `outputs.tf`

A module that silently creates a CloudWatch alarm or an IAM policy attached to an external role is a debugging nightmare.

### 4. Outputs for Everything

Every resource ARN, ID, and name should be an output. Callers should never need to reconstruct resource identifiers from naming conventions — outputs make the implicit explicit:

```hcl
# Bad: caller reconstructs the role ARN
role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.role_name}"

# Good: module outputs the ARN directly
role_arn = module.app_role.role_arn
```

### 5. Validate Inputs — Fail Before Apply

Every variable that could be misconfigured should have a `validation` block. See `iam-role/variables.tf` for examples. Validation runs during `terraform plan` — no AWS API calls needed to catch the error.

---

## Module Versioning

### Git Tag Strategy

```hcl
# Pin to a specific semantic version tag
module "iam_role" {
  source = "git::https://github.com/myorg/terraform-modules.git//iam-role?ref=v2.3.1"
}

# NEVER use branch references — branches are mutable
# BAD:
module "iam_role" {
  source = "git::https://github.com/myorg/terraform-modules.git//iam-role?ref=main"
}
```

Semantic versioning for modules:

| Version bump | When |
|---|---|
| `PATCH` (2.3.0 → 2.3.1) | Bug fix, no variable interface change |
| `MINOR` (2.3.1 → 2.4.0) | New optional variable, backward-compatible |
| `MAJOR` (2.4.0 → 3.0.0) | Breaking change: removed variable, renamed output, different resource type |

### Terraform Registry (Public or Private)

For large teams, publish modules to a Terraform registry:

```hcl
# Terraform public registry
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.4"
}

# Terraform Cloud private registry (enterprise)
module "iam_role" {
  source  = "app.terraform.io/myorg/iam-role/aws"
  version = "~> 2.3"
}
```

Registry modules use the `version` constraint (not `ref`) and are cached by the registry — no Git authentication required in CI.

### Upgrade Process

1. Bump the version pin in the calling module
2. Run `terraform init -upgrade` to fetch the new version
3. Run `terraform plan` — review the diff carefully
4. Test in dev, then staging
5. Apply to prod in the next maintenance window

---

## Module Testing

### Terratest

[Terratest](https://terratest.gruntwork.io/) is a Go testing library for Terraform modules. It:
1. Runs `terraform apply` in a test AWS account
2. Validates outputs with assertions
3. Runs `terraform destroy` to clean up

```go
// test/iam_role_test.go
func TestIAMRoleModule(t *testing.T) {
    t.Parallel()

    terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
        TerraformDir: "../examples/ec2-instance-profile",
        Vars: map[string]interface{}{
            "role_name":       "terratest-role-" + random.UniqueId(),
            "trusted_service": "ec2.amazonaws.com",
        },
    })

    defer terraform.Destroy(t, terraformOptions)
    terraform.InitAndApply(t, terraformOptions)

    roleArn := terraform.Output(t, terraformOptions, "role_arn")
    assert.Contains(t, roleArn, ":role/")
    assert.Contains(t, roleArn, "terratest-role-")

    // Verify the role exists in AWS
    iamClient := aws.NewIamClient(t, "us-east-1")
    roleOutput, err := iamClient.GetRole(&iam.GetRoleInput{
        RoleName: aws.String(terraform.Output(t, terraformOptions, "role_name")),
    })
    require.NoError(t, err)
    assert.NotNil(t, roleOutput.Role)
}
```

### Checkov for Modules

Run checkov against module examples to catch security misconfigurations before they reach any environment:

```yaml
# .github/workflows/module-test.yml
- name: checkov on module examples
  run: |
    checkov -d modules/iam-role/examples \
      --framework terraform \
      --check CKV_AWS_1,CKV_AWS_2,CKV_AWS_274 \
      --compact
```

### Unit Tests with `terraform test` (Terraform 1.6+)

Terraform 1.6 added native test support:

```hcl
# modules/iam-role/tests/ec2_profile.tftest.hcl

run "creates_ec2_role_with_instance_profile" {
  variables {
    role_name               = "test-ec2-role"
    trusted_service         = "ec2.amazonaws.com"
    create_instance_profile = true
  }

  assert {
    condition     = output.role_arn != ""
    error_message = "role_arn output should not be empty"
  }

  assert {
    condition     = output.instance_profile_arn != ""
    error_message = "instance_profile_arn should not be empty when create_instance_profile = true"
  }
}
```

---

## Module Documentation

### terraform-docs

[terraform-docs](https://terraform-docs.io/) generates documentation from Terraform source files:

```bash
terraform-docs markdown table --output-file README.md modules/iam-role/
```

This generates an inputs/outputs table from `variables.tf` and `outputs.tf` automatically. Keep the `README.md` source of truth section above the generated block:

```markdown
<!-- BEGIN_TF_DOCS -->
## Requirements
...auto-generated...
## Inputs
...auto-generated...
## Outputs
...auto-generated...
<!-- END_TF_DOCS -->
```

Add `terraform-docs` as a pre-commit hook so documentation stays synchronized with code:

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/terraform-docs/terraform-docs
    hooks:
      - id: terraform-docs-go
        args: ["modules/iam-role"]
```

---

## Available Modules

### `iam-role`

Creates an IAM role with configurable trust policy. Supports EC2 instance profiles, Lambda execution roles, cross-account assume-role, and GitHub Actions OIDC.

| Input | Type | Default | Required | Description |
|---|---|---|---|---|
| `role_name` | string | — | ✅ | IAM role name |
| `trusted_service` | string | `""` | ❌ | AWS service principal (e.g., `ec2.amazonaws.com`) |
| `trusted_account_id` | string | `""` | ❌ | AWS account ID for cross-account trust |
| `oidc_provider_arn` | string | `""` | ❌ | OIDC provider ARN for federated trust (GitHub Actions) |
| `oidc_subject` | string | `""` | ❌ | OIDC subject claim (e.g., `repo:org/repo:*`) |
| `managed_policy_arns` | list(string) | `[]` | ❌ | AWS managed or customer managed policies to attach |
| `inline_policy_json` | string | `""` | ❌ | JSON string of an inline policy to attach |
| `create_instance_profile` | bool | `false` | ❌ | Create an EC2 instance profile for this role |
| `path` | string | `"/"` | ❌ | IAM path for the role |
| `max_session_duration` | number | `3600` | ❌ | Max session duration in seconds (900–43200) |
| `tags` | map(string) | `{}` | ❌ | Resource tags |

| Output | Description |
|---|---|
| `role_arn` | IAM role ARN |
| `role_name` | IAM role name |
| `role_id` | IAM role unique ID |
| `instance_profile_arn` | Instance profile ARN (empty string if `create_instance_profile = false`) |
| `instance_profile_name` | Instance profile name (empty string if `create_instance_profile = false`) |

---

### `vpc` (Planned)

Three-tier VPC: public, private app, and private data subnets across 3 AZs. Includes NAT GW (one per AZ for HA), VPC Flow Logs, S3 endpoint (Gateway), and SSM/ECR VPC endpoints.

---

### `s3` (Planned)

Hardened S3 bucket: SSE-KMS, versioning, public access block, lifecycle policies, access logging, bucket policy with TLS enforcement. Matches the reference implementation in `storage/terraform/main.tf`.

---

### `ec2-asg` (Planned)

Opinionated EC2 ASG with Launch Template, mixed Spot/On-Demand, ALB, and Instance Refresh. Wraps the reference implementation in `compute/terraform/main.tf`.

---

### `rds` (Planned)

Aurora Serverless v2 cluster with RDS Proxy and Secrets Manager rotation. Wraps the reference implementation in `database/terraform/main.tf`.
