################################################################################
# Storage — Production S3 Reference Implementation
#
# This module provisions a production-hardened S3 bucket with:
#   - KMS CMK encryption (customer-managed key with rotation)
#   - Object Lock (GOVERNANCE mode for data integrity)
#   - Cross-region replication to a secondary region
#   - Intelligent-Tiering + lifecycle rules for cost optimization
#   - Hardened bucket policy: deny HTTP, deny unencrypted uploads, deny non-KMS
#   - CORS for web application integration
################################################################################

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.30"
    }
  }

  backend "s3" {
    bucket         = "myorg-tfstate-prod"
    key            = "storage/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "myorg-tfstate-lock"
    kms_key_id     = "alias/myorg-tfstate"
  }
}

# Primary region provider
provider "aws" {
  region = var.primary_region
  alias  = "primary"

  default_tags {
    tags = merge(var.tags, {
      ManagedBy   = "terraform"
      Module      = "storage"
      Environment = var.environment
    })
  }
}

# Secondary region provider for replication destination
provider "aws" {
  region = var.secondary_region
  alias  = "secondary"

  default_tags {
    tags = merge(var.tags, {
      ManagedBy   = "terraform"
      Module      = "storage"
      Environment = var.environment
      Role        = "replication-destination"
    })
  }
}

data "aws_caller_identity" "current" {
  provider = aws.primary
}

data "aws_partition" "current" {
  provider = aws.primary
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

################################################################################
# KMS CMK — Primary Region
#
# WHY a CMK for application data?
# - You control the key policy: limit which principals can decrypt data
# - Every encrypt/decrypt is logged in CloudTrail — data access audit trail
# - Key rotation is automatic — no certificate rotation processes to manage
# - Required for compliance frameworks (SOC 2 CC6.1, PCI DSS 3.4, HIPAA §164.312)
################################################################################

resource "aws_kms_key" "s3" {
  provider                = aws.primary
  description             = "KMS CMK for ${var.bucket_name} S3 bucket encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  # WHY 30-day deletion window?
  # Objects encrypted with this key cannot be decrypted after the key is deleted.
  # 30 days gives maximum time to recover from accidental deletion before data
  # becomes permanently inaccessible. AWS minimum is 7 days — 30 is safer.
  multi_region = true
  # WHY multi-region?
  # With multi-region keys, the same key material is replicated to the secondary
  # region. This means replicated S3 objects (which carry over their encryption)
  # can be decrypted in the DR region without key material export.
  # Without multi-region keys, you need a separate CMK in each region.

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootFullControl"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # Allow S3 service to use the key for SSE
        Sid    = "AllowS3ServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        # Allow the application role to read/write objects
        Sid    = "AllowApplicationRoleAccess"
        Effect = "Allow"
        Principal = {
          AWS = var.application_role_arn
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        # Allow the security account to audit key usage (read-only)
        Sid    = "AllowSecurityAccountAudit"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${var.security_account_id}:root"
        }
        Action = [
          "kms:DescribeKey",
          "kms:GetKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:ListGrants"
        ]
        Resource = "*"
        # WHY cross-account audit access?
        # In a multi-account AWS Organizations setup, the security account
        # runs GuardDuty, Security Hub, and Config aggregator. Allowing it
        # to inspect key policies supports centralized compliance monitoring
        # without granting data access.
      }
    ]
  })
}

resource "aws_kms_alias" "s3" {
  provider      = aws.primary
  name          = "alias/${var.environment}-${var.bucket_name}"
  target_key_id = aws_kms_key.s3.key_id
}

# Replica key in secondary region — required for cross-region replication with SSE-KMS
resource "aws_kms_replica_key" "s3_replica" {
  provider                = aws.secondary
  description             = "Replica of ${var.bucket_name} KMS key for ${var.secondary_region}"
  deletion_window_in_days = 30
  primary_key_arn         = aws_kms_key.s3.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootFullControl"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowS3ReplicationServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "s3_replica" {
  provider      = aws.secondary
  name          = "alias/${var.environment}-${var.bucket_name}-replica"
  target_key_id = aws_kms_replica_key.s3_replica.key_id
}

################################################################################
# Access Log Bucket (Primary Region)
################################################################################

resource "aws_s3_bucket" "logs" {
  provider = aws.primary
  bucket   = "${var.bucket_name}-access-logs"

  force_destroy = false
}

resource "aws_s3_bucket_versioning" "logs" {
  provider = aws.primary
  bucket   = aws_s3_bucket.logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  provider = aws.primary
  bucket   = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  provider = aws.primary
  bucket   = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  provider = aws.primary
  bucket   = aws_s3_bucket.logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }
  }
}

################################################################################
# Primary Application Bucket
################################################################################

resource "aws_s3_bucket" "main" {
  provider = aws.primary
  bucket   = var.bucket_name

  force_destroy = false

  # WHY Object Lock requires it on bucket creation?
  # Object Lock is configured at bucket creation time and cannot be enabled
  # on an existing bucket. Plan for it from day zero if compliance requires it.
  object_lock_enabled = true

  lifecycle {
    prevent_destroy = true
  }
}

# Disable ACLs — use bucket policies exclusively
resource "aws_s3_bucket_ownership_controls" "main" {
  provider = aws.primary
  bucket   = aws_s3_bucket.main.id

  rule {
    object_ownership = "BucketOwnerEnforced"
    # WHY BucketOwnerEnforced?
    # Disables ACLs completely. All access is managed via IAM + bucket policy.
    # Eliminates the confusion of two separate access control systems.
    # Required for Object Lock in COMPLIANCE mode.
  }
}

# Versioning — required for Object Lock and replication
resource "aws_s3_bucket_versioning" "main" {
  provider = aws.primary
  bucket   = aws_s3_bucket.main.id

  versioning_configuration {
    status = "Enabled"
    # WHY required for Object Lock?
    # Object Lock works by locking specific object versions.
    # Without versioning, there are no versions to lock.
  }

  depends_on = [aws_s3_bucket_ownership_controls.main]
}

# Encryption — SSE-KMS with CMK
resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  provider = aws.primary
  bucket   = aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true
    # WHY bucket_key_enabled?
    # Reduces KMS API calls by 99% — each object PUT/GET with SSE-KMS
    # would otherwise make a KMS API call. Bucket keys create a short-lived
    # data key used for multiple objects. Significant cost reduction at scale.
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "main" {
  provider = aws.primary
  bucket   = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  depends_on = [aws_s3_bucket_ownership_controls.main]
}

# Access logging
resource "aws_s3_bucket_logging" "main" {
  provider = aws.primary
  bucket   = aws_s3_bucket.main.id

  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3-access-logs/${var.bucket_name}/"
}

# Lifecycle rules — cost optimization
resource "aws_s3_bucket_lifecycle_configuration" "main" {
  provider = aws.primary
  bucket   = aws_s3_bucket.main.id

  depends_on = [aws_s3_bucket_versioning.main]

  rule {
    id     = "data-lifecycle"
    status = "Enabled"

    filter {
      prefix = "data/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
      # WHY 30 days minimum for IA?
      # Objects in Standard-IA are billed for a minimum of 30 days.
      # Transitioning before 30 days does not save money and may cost more.
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
      # Glacier Instant Retrieval: archive cost (~$0.004/GB) with
      # millisecond retrieval. Best of both worlds for compliance archives
      # that need occasional access.
    }

    expiration {
      days = 365
      # Adjust to your data retention requirements.
      # Remove this block for data that must be retained indefinitely.
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
      # WHY 90 days for noncurrent versions?
      # Gives enough time to recover from accidental overwrites or
      # ransomware that encrypts objects. Beyond 90 days, old versions
      # are unlikely to be needed for recovery.
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "logs-lifecycle"
    status = "Enabled"

    filter {
      prefix = "logs/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
      # Logs need to be retained for compliance but are rarely accessed.
      # Flexible retrieval (hours) is acceptable for log archives.
    }

    expiration {
      days = var.log_retention_days
    }
  }
}

# Intelligent Tiering — for objects with unpredictable access patterns
resource "aws_s3_bucket_intelligent_tiering_configuration" "main" {
  provider = aws.primary
  bucket   = aws_s3_bucket.main.id
  name     = "entire-bucket"

  tiering {
    access_tier = "DEEP_ARCHIVE_ACCESS"
    days        = 180
    # Objects not accessed in 180 days move to Deep Archive tier
    # Retrieval: 12 hours | Cost: $0.00099/GB — lowest available
  }

  tiering {
    access_tier = "ARCHIVE_ACCESS"
    days        = 90
    # Objects not accessed in 90 days move to Archive tier
    # Retrieval: minutes-hours | Cost: $0.004/GB
  }
}

# Object Lock — GOVERNANCE mode
resource "aws_s3_bucket_object_lock_configuration" "main" {
  provider = aws.primary
  bucket   = aws_s3_bucket.main.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.object_lock_retention_days
      # WHY GOVERNANCE mode (not COMPLIANCE)?
      # GOVERNANCE allows users with s3:BypassGovernanceRetention to override.
      # COMPLIANCE allows NO overrides — not even the root account.
      # Use GOVERNANCE as the default; switch to COMPLIANCE only when a specific
      # regulation (SEC 17a-4, CFTC Rule 1.31) explicitly requires immutable storage.
    }
  }

  depends_on = [aws_s3_bucket_versioning.main]
}

# CORS — for web application direct-to-S3 uploads (presigned URLs)
resource "aws_s3_bucket_cors_configuration" "main" {
  provider = aws.primary
  bucket   = aws_s3_bucket.main.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "HEAD"]
    allowed_origins = var.cors_allowed_origins
    # WHY not ["*"] for origins?
    # Wildcard origins allow any website to make cross-origin requests.
    # Restrict to your actual application origins (e.g., ["https://app.example.com"])
    # to prevent other websites from using presigned URLs generated by your API.

    expose_headers  = ["ETag", "x-amz-request-id"]
    max_age_seconds = 3600
  }
}

# Bucket policy — deny HTTP, deny unencrypted uploads, allow only specific roles
resource "aws_s3_bucket_policy" "main" {
  provider = aws.primary
  bucket   = aws_s3_bucket.main.id

  depends_on = [aws_s3_bucket_public_access_block.main]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Non-TLS denial — required by CIS Benchmark and most compliance frameworks
        Sid       = "DenyNonTLSRequests"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.main.arn, "${aws_s3_bucket.main.arn}/*"]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        # Require SSE-KMS on all uploads — belt-and-suspenders beyond default encryption
        Sid       = "DenyNonKMSEncryptedUploads"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.main.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      },
      {
        # Require THIS specific CMK — prevent uploads with other KMS keys
        Sid       = "DenyWrongKMSKey"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.main.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption-aws-kms-key-id" = aws_kms_key.s3.arn
          }
        }
      },
      {
        # Explicit allow for the application role — avoids implicit deny trap
        # after the denies above
        Sid    = "AllowApplicationRoleAccess"
        Effect = "Allow"
        Principal = {
          AWS = var.application_role_arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetObjectVersion",
          "s3:GetBucketVersioning",
          "s3:GetBucketLocation"
        ]
        Resource = [aws_s3_bucket.main.arn, "${aws_s3_bucket.main.arn}/*"]
      },
      {
        # Allow the replication role to read objects for CRR
        Sid    = "AllowReplicationSourceRead"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.replication.arn
        }
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging",
          "s3:ListBucket",
          "s3:GetReplicationConfiguration"
        ]
        Resource = [aws_s3_bucket.main.arn, "${aws_s3_bucket.main.arn}/*"]
      }
    ]
  })
}

################################################################################
# Replication — Cross-Region (DR)
################################################################################

# Destination bucket in secondary region
resource "aws_s3_bucket" "replica" {
  provider = aws.secondary
  bucket   = "${var.bucket_name}-replica-${var.secondary_region}"

  force_destroy       = false
  object_lock_enabled = true
}

resource "aws_s3_bucket_ownership_controls" "replica" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.replica.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "replica" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.replica.id

  # Versioning must be enabled on the destination bucket for replication to work
  versioning_configuration {
    status = "Enabled"
  }

  depends_on = [aws_s3_bucket_ownership_controls.replica]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "replica" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.replica.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_replica_key.s3_replica.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "replica" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.replica.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  depends_on = [aws_s3_bucket_ownership_controls.replica]
}

# IAM role for CRR
resource "aws_iam_role" "replication" {
  provider = aws.primary
  name     = "${var.environment}-s3-replication-${var.bucket_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "replication" {
  provider = aws.primary
  name     = "s3-replication-policy"
  role     = aws_iam_role.replication.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.main.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Resource = "${aws_s3_bucket.main.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Resource = "${aws_s3_bucket.replica.arn}/*"
      },
      {
        # Required for replication with SSE-KMS in source region
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.s3.arn
      },
      {
        # Required to re-encrypt with destination region KMS key
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_replica_key.s3_replica.arn
      }
    ]
  })
}

# Cross-region replication configuration on source bucket
resource "aws_s3_bucket_replication_configuration" "main" {
  provider = aws.primary
  role     = aws_iam_role.replication.arn
  bucket   = aws_s3_bucket.main.id

  depends_on = [aws_s3_bucket_versioning.main]

  rule {
    id     = "replicate-all-to-${var.secondary_region}"
    status = "Enabled"

    filter {} # Empty filter = replicate all objects

    destination {
      bucket        = aws_s3_bucket.replica.arn
      storage_class = "STANDARD_IA"
      # WHY STANDARD_IA for replica?
      # The replica is for DR — it won't be accessed unless the primary region fails.
      # Standard-IA provides the same durability as Standard at 45% lower cost.
      # If a failover occurs, you can change storage class then.

      encryption_configuration {
        replica_kms_key_id = aws_kms_replica_key.s3_replica.arn
        # WHY specify replica KMS key?
        # Without this, replicated objects are encrypted with the destination
        # bucket's default encryption. Specifying the CMK ensures the same
        # key policy (and audit trail) applies in the DR region.
      }
    }

    delete_marker_replication {
      status = "Enabled"
      # WHY replicate delete markers?
      # When an object is deleted from the source, a delete marker is created.
      # Without this setting, the replica retains the old version — the DR bucket
      # diverges from the source. Replicating delete markers keeps them in sync.
    }
  }
}

################################################################################
# Outputs
################################################################################

################################################################################
# Variables
################################################################################
