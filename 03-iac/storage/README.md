# Storage Architecture

> **Reference implementation:** Production S3 with KMS CMK, Object Lock, intelligent tiering, cross-region replication, and hardened bucket policy.

---

## Table of Contents

1. [S3 — Storage Classes and Lifecycle](#s3--storage-classes-and-lifecycle)
2. [EFS — When to Use EFS vs EBS vs S3](#efs--when-to-use-efs-vs-ebs-vs-s3)
3. [FSx — Managed File Systems](#fsx--managed-file-systems)
4. [EBS — Volume Types and Encryption](#ebs--volume-types-and-encryption)
5. [Storage Decision Matrix](#storage-decision-matrix)
6. [S3 Security](#s3-security)
7. [FAQ](#-faq)
8. [AWS Documentation Links](#aws-documentation-links)

---

## S3 — Storage Classes and Lifecycle

### Storage Classes (in cost order, most to least expensive)

| Class | Retrieval | Min Duration | Use Case |
|---|---|---|---|
| **S3 Standard** | Milliseconds | None | Active data, frequently accessed |
| **S3 Intelligent-Tiering** | Milliseconds | None | Unknown or changing access patterns |
| **S3 Standard-IA** | Milliseconds | 30 days | Infrequent access, still needs low latency |
| **S3 One Zone-IA** | Milliseconds | 30 days | Infrequent, reproducible data, single AZ acceptable |
| **S3 Glacier Instant Retrieval** | Milliseconds | 90 days | Archives needing occasional immediate access |
| **S3 Glacier Flexible Retrieval** | Minutes–hours | 90 days | Compliance archives, DR |
| **S3 Glacier Deep Archive** | Hours | 180 days | Long-term regulatory archives (7-year retention) |

### Lifecycle Policies

Lifecycle policies automate cost optimization without changing application code:

```hcl
rule {
  id     = "data-lifecycle"
  status = "Enabled"

  transition {
    days          = 30
    storage_class = "STANDARD_IA"   # 30-day minimum — ensure access is truly infrequent
  }

  transition {
    days          = 90
    storage_class = "GLACIER_IR"    # Glacier Instant — still fast retrieval, much cheaper
  }

  expiration {
    days = 365   # Delete after 1 year — adjust to compliance requirements
  }
}
```

> **Why not go straight to Glacier?**  
> Glacier Flexible has retrieval times of 1-12 hours. If a bug or audit requires re-accessing data at the 60-day mark, you cannot afford hours of retrieval delay. Glacier Instant Retrieval gives archive pricing with millisecond access.

### Intelligent Tiering

Intelligent Tiering monitors access patterns and automatically moves objects between tiers. It is the right default for buckets where access patterns are unpredictable:

- No operational overhead — AWS manages transitions automatically
- Small monitoring fee (~$0.0025/1,000 objects/month)
- No retrieval fees for the Frequent and Infrequent Access tiers
- Opt-in Archive tiers (async retrieval) available for objects not accessed in 90+ days

---

## EFS — When to Use EFS vs EBS vs S3

EFS (Elastic File System) is a managed NFS service — a POSIX file system that multiple EC2 instances can mount simultaneously.

### EFS vs EBS

| | EFS | EBS |
|---|---|---|
| **Attachment** | Many instances simultaneously | One instance (Multi-Attach for io2, but complex) |
| **Scaling** | Elastic — grows/shrinks automatically | Fixed size, requires resize operation |
| **Performance** | Milliseconds; up to 3 GB/s (Provisioned Throughput) | Sub-millisecond; up to 64,000 IOPS (io2 BE) |
| **Protocol** | NFS v4.1 | Block device |
| **Cost** | ~$0.30/GB/month (Standard) | ~$0.08/GB/month (gp3) |
| **Use case** | Shared storage, content management, home directories | Database files, single-instance workloads |

### EFS vs S3

| | EFS | S3 |
|---|---|---|
| **Access protocol** | POSIX (mount point) | HTTP API |
| **Latency** | Low (1-10ms) | Higher (10-100ms for first byte) |
| **Concurrency** | Shared mount, standard file locking | No file locking (eventual consistency on overwrites) |
| **Metadata** | Full POSIX attributes | Object metadata only |
| **Use case** | Applications that need a mounted filesystem | Object storage, web serving, data lakes |

**Choose EFS when:** Your application code expects a filesystem path (e.g., a CMS storing uploads, a Kubernetes persistent volume, home directories for EC2 instances, shared config files across a fleet).

**Avoid EFS when:** You need block-level performance (databases) or your application can use an S3 SDK (use S3 — it is cheaper and infinitely scalable).

### EFS Performance Modes

- **General Purpose** (default): Sub-millisecond latency. Max 35,000 file operations/second. Use for latency-sensitive workloads.
- **Max I/O**: Higher aggregate throughput and IOPS, but higher latency (5-10ms vs <1ms). Use for big data and HPC workloads with highly parallelized access patterns.

### EFS Throughput Modes

- **Elastic** (recommended): Automatically scales throughput up to 3 GB/s read, 1 GB/s write. Pay per GB transferred. Best for bursty workloads.
- **Provisioned**: Fixed throughput independent of storage size. Use when you need guaranteed throughput and Elastic would be more expensive given your access pattern.
- **Bursting** (legacy): Throughput scales with stored data. Problematic for small filesystems that need high throughput.

---

## FSx — Managed File Systems

AWS FSx provides four managed file system engines, each solving a specific workload:

### FSx for Windows File Server

- **Protocol**: SMB 2.0–3.1.1
- **Use case**: Windows workloads requiring shared storage (IIS, SQL Server data files on a shared volume, user home directories in Active Directory environments)
- **Key feature**: Full Active Directory integration — domain-joined access control, DFS namespaces
- **When to use**: Lifting and shifting Windows file servers to AWS without application re-engineering

### FSx for Lustre

- **Protocol**: POSIX (native Lustre client)
- **Use case**: HPC, ML training, genome sequencing, financial modelling — any workload needing hundreds of GB/s throughput
- **Key feature**: Native integration with S3 — import datasets from S3, export results back
- **Performance**: Up to 1 TB/s aggregate throughput, sub-millisecond latency
- **When to use**: Parallel processing jobs where EFS throughput is insufficient

### FSx for NetApp ONTAP

- **Protocols**: NFS, SMB, iSCSI simultaneously
- **Use case**: Lift-and-shift of on-premises ONTAP storage — no application changes needed
- **Key features**: SnapMirror replication, deduplication, compression, instant clones for dev/test
- **When to use**: Enterprises with existing ONTAP licensing, or workloads requiring multi-protocol access

### FSx for OpenZFS

- **Protocol**: NFS
- **Use case**: Applications requiring ZFS semantics (instant snapshots, cloning, high throughput)
- **Key feature**: Up to 21 GB/s throughput, 1 million IOPS
- **When to use**: EBS/EFS alternatives for high-performance NFS workloads needing ZFS features

---

## EBS — Volume Types and Encryption

### Volume Type Comparison

| Type | IOPS | Throughput | Latency | Use Case |
|---|---|---|---|---|
| **gp3** | 3,000–16,000 (configurable) | 125–1,000 MB/s | Single-digit ms | General purpose — default choice |
| **gp2** | 3,000 base; 3 IOPS/GB (max 16,000) | 250 MB/s max | Single-digit ms | Legacy — migrate to gp3 |
| **io2 Block Express** | Up to 256,000 | Up to 4,000 MB/s | Sub-ms | Highest-performance databases (Oracle, SQL Server) |
| **io1** | Up to 64,000 | Up to 1,000 MB/s | Single-digit ms | Legacy io2 predecessor — use io2 |
| **st1** | 500 IOPS | 500 MB/s | Single-digit ms | Sequential-access big data, log processing |
| **sc1** | 250 IOPS | 250 MB/s | Single-digit ms | Archival, infrequently accessed |

> **Migrate gp2 to gp3:** gp3 is 20% cheaper than gp2 and decouples IOPS from volume size. With gp2, you had to over-provision volume size to get IOPS (3 IOPS/GB). With gp3, you configure IOPS independently. No data migration needed — modify the volume type in-place.

### EBS Encryption

Enable EBS encryption at the account level (once) and it applies to all new volumes in that region:

```bash
aws ec2 enable-ebs-encryption-by-default --region us-east-1
```

Enforce it in Launch Templates explicitly (belt-and-suspenders). Use KMS CMK for production — it provides a custom key policy and CloudTrail audit trail.

### EBS Snapshots

Snapshots are incremental — only changed blocks since the last snapshot are stored. Use `Data Lifecycle Manager` (DLM) or `AWS Backup` for automated snapshot schedules:

```hcl
resource "aws_dlm_lifecycle_policy" "ebs_backup" {
  description        = "Daily EBS snapshots, 30-day retention"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    policy_type = "EBS_SNAPSHOT_MANAGEMENT"

    target_tags = {
      "backup" = "daily"
    }

    schedule {
      name = "daily-snapshots"
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }
      retain_rule {
        count = 30
      }
      copy_tags = true
    }
  }
}
```

---

## Storage Decision Matrix

| Workload | Recommended Storage | Why |
|---|---|---|
| Web static assets, CDN origin | S3 Standard | Unlimited scale, native CloudFront integration |
| Application data, user uploads | S3 Standard + Intelligent-Tiering | Unknown access patterns, zero ops |
| Compliance archives (7-year) | S3 Glacier Deep Archive + Object Lock | Lowest cost, WORM compliance |
| Database data files | EBS io2 (high-perf) or gp3 (general) | Block storage, sub-ms latency |
| Shared config across EC2 fleet | EFS General Purpose | Multi-mount, elastic capacity |
| ML training dataset (100 TB+) | FSx for Lustre + S3 integration | HPC throughput, S3 data import |
| Windows SMB file share | FSx for Windows | SMB + AD integration |
| On-prem ONTAP migration | FSx for NetApp ONTAP | Protocol-compatible, zero app changes |
| Docker container volumes (ECS/EKS) | EFS (ReadWriteMany) or EBS (ReadWriteOnce) | Depends on multi-pod sharing need |
| CloudTrail / VPC Flow Logs | S3 Standard + lifecycle to Glacier | Append-only, seldom read |

---

## S3 Security

### Bucket Policies vs ACLs

> **Rule: Disable ACLs. Use bucket policies exclusively.**  
> AWS recommends disabling S3 ACLs in favor of bucket policies ([Object Ownership = BucketOwnerEnforced](https://docs.aws.amazon.com/AmazonS3/latest/userguide/about-object-ownership.html)). ACLs predate IAM and are a separate, confusing access control layer. When both are in effect, the most permissive one wins — leading to unintentional public access.

```hcl
resource "aws_s3_bucket_ownership_controls" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    object_ownership = "BucketOwnerEnforced"
    # Disables ACLs entirely. All access is controlled by bucket policies and IAM.
  }
}
```

### Object Lock (WORM)

Object Lock prevents deletion or modification of objects for a defined period. Two modes:

- **GOVERNANCE mode**: Prevents most users from deleting. Users with `s3:BypassGovernanceRetention` can override. Use for: data integrity (preventing accidental deletion) while allowing exceptions for admins.
- **COMPLIANCE mode**: No one can delete or modify — not even the root account. Cannot be disabled once enabled. Use for: SEC Rule 17a-4, FINRA, HIPAA — regulations that require tamper-proof records.

### S3 Access Points

Access Points are named entry points into a bucket with distinct permissions and network controls:

```hcl
resource "aws_s3_access_point" "analytics" {
  bucket = aws_s3_bucket.data.id
  name   = "analytics-read-only"

  vpc_configuration {
    vpc_id = var.vpc_id   # This access point is only accessible from the VPC
  }

  policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.analytics_role_arn }
      Action    = "s3:GetObject"
      Resource  = "arn:aws:s3:us-east-1:${var.account_id}:accesspoint/analytics-read-only/object/*"
    }]
  })
}
```

Access Points are ideal when multiple teams or services need different views of the same bucket with different permissions — without managing a complex monolithic bucket policy.

---

## ❓ FAQ

**Q: Should I enable S3 Versioning on all buckets?**

A: Enable versioning on buckets that hold:
- Terraform state (essential — see state-backend/)
- Application artifacts (deployment rollback)
- User-generated content (accidental delete recovery)
- Configuration files (audit trail of changes)

Do not enable versioning on:
- Log buckets (logs are write-once, versioning doubles storage cost)
- Transient/staging buckets that are frequently re-written (same cost concern)
- Buckets using Object Lock (Object Lock has its own versioning semantics)

---

**Q: What's the difference between S3 replication and S3 batch operations?**

A: Different tools for different purposes:
- **Cross-Region Replication (CRR)** and **Same-Region Replication (SRR)**: Continuously replicate new objects as they are written. Used for DR (CRR), data locality, compliance (SRR for keeping data in a specific region). Does **not** replicate existing objects.
- **S3 Batch Operations**: One-time or scheduled operations on existing objects (copy, tag, restore from Glacier, invoke Lambda). Use Batch Operations to backfill replication for objects that existed before replication was enabled.

---

**Q: How do I securely allow cross-account S3 access?**

A: The pattern for cross-account S3 access:

1. **Source bucket policy**: Allow the external account's IAM role to read
2. **Target account IAM policy**: Allow the role to perform the S3 actions
3. **Object ownership**: `BucketOwnerEnforced` — objects written by external accounts belong to the bucket owner

For large-scale cross-account access, prefer S3 Access Points with a VPC endpoint. This scopes access to specific network paths and avoids bloated bucket policies.

---

**Q: When does S3 Intelligent-Tiering make financial sense?**

A: Intelligent-Tiering has a per-object monitoring charge of $0.0025/1,000 objects/month. For very small objects (< 128 KB), this monitoring charge exceeds the potential savings from tiering. AWS does not tier objects smaller than 128 KB even if Intelligent-Tiering is enabled. Intelligent-Tiering is most cost-effective for:
- Objects ≥ 128 KB
- Access patterns that are genuinely unknown or seasonal
- Buckets where some percentage of objects is accessed rarely but retrieval speed is still important

---

**Q: How do I find and remove public S3 buckets in a multi-account environment?**

A: Use **S3 Block Public Access at the account level** (not just bucket level):

```bash
aws s3control put-public-access-block \
  --account-id 123456789012 \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
```

Enforce this via an SCP (Service Control Policy) in AWS Organizations so no account can disable it:

```json
{
  "Effect": "Deny",
  "Action": "s3:PutAccountPublicAccessBlock",
  "Resource": "*"
}
```

Use AWS Config rule `s3-bucket-public-read-prohibited` to continuously audit and remediate.

---

**Q: What is S3 Transfer Acceleration and when does it help?**

A: Transfer Acceleration routes uploads through the nearest AWS CloudFront edge location using AWS backbone network to reach S3. It helps when:
- Users are uploading large files (> 1 GB) from geographically distant locations
- Public internet routes to the S3 region are slow (common in Southeast Asia, South America uploading to us-east-1)

It does not help (and adds cost) for:
- Downloads (use CloudFront for that)
- Users within the same AWS region
- Small files where TCP connection overhead dominates

Test with the [S3 Transfer Acceleration Speed Comparison tool](https://s3-accelerate-speedtest.s3-accelerate.amazonaws.com/en/accelerate-speed-comparsion.html) before enabling.

---

## AWS Documentation Links

- [S3 Storage Classes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html)
- [S3 Lifecycle Configuration](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html)
- [S3 Intelligent-Tiering](https://docs.aws.amazon.com/AmazonS3/latest/userguide/intelligent-tiering.html)
- [S3 Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html)
- [S3 Access Points](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-points.html)
- [S3 Object Ownership](https://docs.aws.amazon.com/AmazonS3/latest/userguide/about-object-ownership.html)
- [S3 Cross-Region Replication](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication.html)
- [Amazon EFS Performance Modes](https://docs.aws.amazon.com/efs/latest/ug/performance.html)
- [Amazon FSx Product Family](https://aws.amazon.com/fsx/)
- [EBS Volume Types](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-volume-types.html)
- [EBS Encryption](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/EBSEncryption.html)
