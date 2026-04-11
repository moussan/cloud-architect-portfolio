# Terraform Remote State Backend

> **Must be provisioned before any other module in this repo.**  
> All other root modules reference this bucket and DynamoDB table.

---

## The Chicken-and-Egg Problem

Terraform stores its state in a backend. The recommended backend is S3 + DynamoDB. But the S3 bucket and DynamoDB table are AWS resources — which means Terraform needs to create them. You cannot configure Terraform to use an S3 backend before that S3 bucket exists.

The solution is a deliberate two-phase bootstrap:

### Phase 1 — Local Backend (One Time Only)

Apply `state-backend/terraform/main.tf` with a **local** backend to create the S3 bucket and DynamoDB table:

```bash
cd 03-iac/state-backend/terraform

# 1. Initialize with local backend (no backend block in main.tf yet)
terraform init

# 2. Apply to create the S3 bucket + DynamoDB table
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan

# 3. Note the outputs
terraform output
# state_bucket_name = "myorg-tfstate-prod"
# dynamodb_table_name = "myorg-tfstate-lock"
```

### Phase 2 — Migrate to S3 Backend

Add the `backend "s3"` block to `main.tf`, then run `terraform init -migrate-state`:

```hcl
# Add this block to main.tf after Phase 1
terraform {
  backend "s3" {
    bucket         = "myorg-tfstate-prod"       # from Phase 1 output
    key            = "state-backend/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "myorg-tfstate-lock"        # from Phase 1 output
    kms_key_id     = "alias/myorg-tfstate"
  }
}
```

```bash
# Terraform detects the new backend and offers to migrate local state to S3
terraform init -migrate-state
# Confirm when prompted: yes
```

From this point forward, the state for the bootstrap module itself is in S3. All other modules configure their backends pointing to the same bucket with different `key` values.

> **Why migrate the bootstrap state too?**  
> If the bootstrap state stays local, only the person who ran Phase 1 can manage the state backend resources. Migrating puts everyone on the same footing and gives you version history on the state bucket configuration itself.

---

## Security Requirements for the State Bucket

The state file is one of the most sensitive artifacts in your infrastructure. It contains:
- Database passwords (unless you're using `sensitive = true` and Secrets Manager references)
- Private key material
- All resource IDs, ARNs, and configuration that could accelerate an attack

The bucket must meet every requirement below. See `terraform/main.tf` for the implementation.

| Control | Terraform Resource | Why |
|---|---|---|
| **Versioning** | `aws_s3_bucket_versioning` | Recover from state corruption |
| **MFA Delete** | `aws_s3_bucket_versioning.mfa_delete` | Prevent accidental or malicious version purge |
| **SSE-KMS** | `aws_s3_bucket_server_side_encryption_configuration` | State contains secrets — AES256 is acceptable but CMK preferred |
| **Block All Public Access** | `aws_s3_bucket_public_access_block` | State must never be publicly readable |
| **Access Logging** | `aws_s3_bucket_logging` | Audit who accessed the state file |
| **TLS-only Bucket Policy** | `aws_s3_bucket_policy` | Deny HTTP reads — credentials in transit |
| **Lifecycle Rule** | `aws_s3_bucket_lifecycle_configuration` | Retain 90 days of noncurrent versions, then expire |
| **DynamoDB PITR** | `aws_dynamodb_table.point_in_time_recovery` | Recover the lock table if it's corrupted |

---

## Inputs

| Variable | Description | Default |
|---|---|---|
| `bucket_name` | Name of the S3 state bucket | required |
| `dynamodb_table_name` | Name of the DynamoDB lock table | `"${bucket_name}-lock"` |
| `region` | AWS region | `"us-east-1"` |
| `log_bucket_name` | Name of the access log bucket | `"${bucket_name}-logs"` |
| `noncurrent_version_days` | Days to retain noncurrent state versions | `90` |
| `tags` | Resource tags map | `{}` |

---

## Outputs

| Output | Description |
|---|---|
| `state_bucket_name` | S3 bucket name — used in all backend configurations |
| `state_bucket_arn` | ARN for bucket policy and IAM role references |
| `dynamodb_table_name` | DynamoDB table name — used in all backend configurations |

---

## ❓ FAQ

**Q: Can I use the same state bucket for multiple environments?**

A: Yes. Use a different `key` path per environment per module:
```
key = "prod/compute/terraform.tfstate"
key = "staging/compute/terraform.tfstate"
```
The bucket is shared; the state files are isolated by path. For stricter isolation (different IAM boundaries), use separate buckets per AWS account.

---

**Q: What happens if the state bucket is accidentally deleted?**

A: If versioning and MFA Delete were enabled and the bucket was emptied before deletion, recovery is difficult. This is why `prevent_destroy = true` is set on the bucket resource and deletion protection on the DynamoDB table. If the bucket genuinely needs to be deleted, that requires removing the `prevent_destroy` block, committing the change, and running apply — a deliberate multi-step action that is hard to do accidentally.

---

**Q: Should the state bucket be in the same account as the workloads?**

A: For smaller setups, yes. For enterprise multi-account setups, put the state bucket in a dedicated **tooling** or **shared-services** account. Terraform's CI role in each environment account has cross-account S3 and DynamoDB permissions to the tooling account. This means workload account compromises do not expose the state for other accounts.

---

**Q: How do I rotate the KMS key used for state encryption?**

A: KMS key rotation is handled automatically when `enable_key_rotation = true` is set on the `aws_kms_key` resource. AWS rotates the backing key material annually while keeping the same key ID — existing objects are transparently re-encrypted on access. You do not need to update Terraform configurations or re-apply to benefit from rotation.
