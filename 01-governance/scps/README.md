# Service Control Policies (SCPs) — Deep Dive

> **Why SCPs matter more than IAM policies.**
> IAM policies define what identities *can* do. SCPs define what *no one* in an account can do — not even the account's own IAM administrator, not even `AdministratorAccess`. An SCP deny is the hardest enforcement boundary in the AWS control plane. Get them right and the rest of your security posture is far more defensible.

---

## How SCPs Work

### The Effective Permissions Model

```
Effective Permission = SCP Allowances ∩ IAM Identity Policy Allowances ∩ Resource Policy Allowances
```

For an action to succeed, it must be allowed by **all three** layers simultaneously. A deny in any layer blocks the action.

```
                         AWS API Call
                              │
                              ▼
                   ┌─────────────────────┐
                   │     SCP Check       │
                   │  (Org-level, hard)  │
                   └─────────────────────┘
                              │
                    Denied? ──┼── Yes ──► AccessDenied
                              │
                             No
                              ▼
                   ┌─────────────────────┐
                   │ IAM Policy Check    │
                   │ (Identity-based +   │
                   │  Permission Boundary│
                   │  if present)        │
                   └─────────────────────┘
                              │
                    Denied? ──┼── Yes ──► AccessDenied
                              │
                             No
                              ▼
                   ┌─────────────────────┐
                   │ Resource Policy     │
                   │ Check (if exists)   │
                   └─────────────────────┘
                              │
                    Denied? ──┼── Yes ──► AccessDenied
                              │
                             No
                              ▼
                         ✅ Allowed
```

### Key Rules

1. **SCPs do not apply to the management account.** The management account is exempt from all SCPs. This is why workloads must never run there.
2. **SCPs do not apply to service-linked roles.** AWS service-linked roles bypass SCPs to allow services to function correctly.
3. **An explicit SCP deny cannot be overridden** by any IAM policy, including `AdministratorAccess`.
4. **SCPs are inherited downward.** An SCP on the root applies to every account in the organisation. An SCP on an OU applies to all accounts in that OU and all child OUs.
5. **The effective SCP is the intersection of all SCPs in the inheritance chain** — not a union. Every SCP in the chain must allow the action.

---

## Inheritance Model

```
Organisation Root
│   └── SCP: DenyLeaveOrganization (attached here → applies everywhere)
│   └── SCP: DenyNonAllowedRegions (attached here → applies everywhere)
│
├── Security OU
│   └── SCP: DenyDeleteLogs (extra restriction for security accounts)
│   └── Accounts: Log Archive, Security Tooling
│       Both accounts are constrained by:
│         Root SCPs + Security OU SCPs
│
├── Workloads OU
│   └── SCP: RequireS3SSE
│   │
│   ├── Production OU
│   │   └── SCP: RequireEncryptedTransport (extra restriction)
│   │   └── Accounts: Prod-App-1, Prod-App-2
│   │       Constrained by: Root + Workloads + Production SCPs
│   │
│   └── Non-Prod OU
│       └── Accounts: Dev, Staging
│           Constrained by: Root + Workloads SCPs
│
└── Sandbox OU
    └── Accounts: Sandbox
        Constrained by: Root SCPs only (most permissive)
```

---

## Deny-List vs. Allow-List Strategy

### Deny-List (Recommended for Most Organisations)

Start with a full-access baseline and layer explicit denies:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "*",
      "Resource": "*"
    }
    // Add deny statements for specific prohibited actions
  ]
}
```

**Advantages:**
- New AWS services are automatically permitted without policy changes
- Lower operational overhead
- Easier to audit (review what's denied, not what's allowed)

**Disadvantages:**
- New services accessible immediately — may not be desired in highly regulated environments

### Allow-List (Highly Regulated Environments)

Explicitly permit only the services your organisation uses:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:*",
        "s3:*",
        "rds:*"
        // Only permitted services
      ],
      "Resource": "*"
    }
  ]
}
```

**Advantages:**
- No new service is accessible unless explicitly approved
- Smallest possible attack surface

**Disadvantages:**
- High operational overhead — every new AWS service adoption requires a policy update
- Risk of accidentally blocking services (especially global/meta services like `sts`, `iam`, `support`)

> **Decision:** This portfolio uses deny-list strategy. The operational overhead of maintaining an allow-list across 7+ accounts and 200+ AWS services is not justified for most organisations. If your compliance framework requires an allow-list (some government frameworks do), see the comments in each SCP below for guidance.

---

## Production-Ready SCPs

### SCP 1: DenyNonAllowedRegions

**Purpose:** Enforces data residency. Blocks API calls in any region not in the approved list.

**Why `NotAction` instead of `Action: *`?** IAM, Route 53, CloudFront, and other global services are not region-scoped. Blocking them with a region condition prevents console login and breaks billing. `NotAction` exempts these services from the restriction.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyNonAllowedRegions",
      "Effect": "Deny",
      "NotAction": [
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
        "wellarchitected:*"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": [
            "ca-central-1",
            "us-east-1"
          ]
        }
      }
    }
  ]
}
```

---

### SCP 2: DenyLeaveOrganization

**Purpose:** Prevents the account root user from removing the account from the AWS Organisation.

**Why this is critical:** Without this SCP, a compromised root user can escape all organisational controls (SCPs, centralised logging, consolidated billing) by leaving the organisation. This is a one-way door — once an account leaves, it cannot be rejoined without a new invitation.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyLeaveOrganization",
      "Effect": "Deny",
      "Action": [
        "organizations:LeaveOrganization"
      ],
      "Resource": "*"
    }
  ]
}
```

---

### SCP 3: RequireIMDSv2

**Purpose:** Forces all EC2 instances to use Instance Metadata Service v2 (session-oriented).

**Why IMDSv2 matters:** IMDSv1 responds to any HTTP GET to `169.254.169.254`. An SSRF vulnerability in a web application can silently fetch instance credentials. IMDSv2 requires a PUT request with a TTL header to obtain a token first — a step SSRF cannot replicate. This SCP also blocks `ModifyInstanceMetadataOptions` to prevent downgrading running instances.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RequireIMDSv2OnRunInstances",
      "Effect": "Deny",
      "Action": "ec2:RunInstances",
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringNotEquals": {
          "ec2:MetadataHttpTokens": "required"
        }
      }
    },
    {
      "Sid": "DenyIMDSv2Downgrade",
      "Effect": "Deny",
      "Action": "ec2:ModifyInstanceMetadataOptions",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "ec2:MetadataHttpTokens": "optional"
        }
      }
    }
  ]
}
```

---

### SCP 4: DenyRootAccountActions

**Purpose:** Prevents the account root user from creating access keys or managing MFA. Root must never be used for routine operations.

**Why this matters:** The root user bypasses IAM policies and has unrestricted access. Long-lived root access keys are catastrophic if compromised. This SCP forces the break-glass process for any root access and prevents establishing persistent root credentials.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyRootAccountActions",
      "Effect": "Deny",
      "Action": [
        "iam:CreateAccessKey",
        "iam:CreateVirtualMFADevice",
        "iam:DeleteVirtualMFADevice",
        "iam:DeactivateMFADevice",
        "iam:EnableMFADevice",
        "iam:ResyncMFADevice",
        "iam:UpdateAccountPasswordPolicy"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:PrincipalArn": ["arn:aws:iam::*:root"]
        }
      }
    }
  ]
}
```

---

### SCP 5: RequireS3SSE

**Purpose:** Denies any S3 PutObject call that does not include a server-side encryption header.

**Why this matters:** Without enforced encryption, developers or applications may write unencrypted data to S3 — violating PIPEDA, HIPAA, PCI-DSS, and most other compliance frameworks. This SCP enforces encryption at the organisational level regardless of bucket policy settings.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyS3PutWithoutSSE",
      "Effect": "Deny",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::*/*",
      "Condition": {
        "Null": {
          "s3:x-amz-server-side-encryption": "true"
        }
      }
    },
    {
      "Sid": "DenyS3PutWithNonCompliantEncryption",
      "Effect": "Deny",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::*/*",
      "Condition": {
        "StringNotEquals": {
          "s3:x-amz-server-side-encryption": [
            "aws:kms",
            "AES256"
          ]
        }
      }
    }
  ]
}
```

---

### SCP 6: DenyPublicS3ACLs

**Purpose:** Prevents creating S3 objects or buckets with public-granting ACLs.

**Why ACLs specifically?** S3 Block Public Access is the preferred mechanism, but ACLs can override bucket-level settings in some configurations. This SCP ensures that even if Block Public Access is disabled (which SCP 7 prevents), public ACLs cannot be applied.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyPublicS3ACLs",
      "Effect": "Deny",
      "Action": [
        "s3:PutBucketAcl",
        "s3:PutObjectAcl"
      ],
      "Resource": [
        "arn:aws:s3:::*",
        "arn:aws:s3:::*/*"
      ],
      "Condition": {
        "StringEquals": {
          "s3:x-amz-acl": [
            "public-read",
            "public-read-write",
            "authenticated-read"
          ]
        }
      }
    }
  ]
}
```

---

### SCP 7: DenyPublicS3Buckets

**Purpose:** Prevents disabling S3 Block Public Access at the account or bucket level.

**Why this is distinct from SCP 6:** S3 Block Public Access is a separate control from ACLs. Even without public ACLs, a bucket policy can grant public access if Block Public Access is disabled. This SCP ensures Block Public Access cannot be turned off.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyDisablingS3BPA",
      "Effect": "Deny",
      "Action": [
        "s3:PutAccountPublicAccessBlock",
        "s3:PutBucketPublicAccessBlock"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "s3:PublicAccessBlockConfiguration.BlockPublicAcls": "false"
        }
      }
    }
  ]
}
```

---

### SCP 8: RequireMFAForConsoleLogin

**Purpose:** Denies all API actions for IAM users who have not authenticated with MFA.

**Why this matters:** IAM users with only a password can access the console without MFA. If a password is phished, the attacker has full IAM-user-level access. This SCP forces MFA before any meaningful action can be taken, limiting the damage from compromised passwords.

**Note:** This SCP applies to IAM users, not Identity Center users (who have separate MFA controls). In an Identity Center environment, this SCP provides defence-in-depth for any legacy IAM users.

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
        },
        "Bool": {
          "aws:ViaAWSService": "false"
        }
      }
    }
  ]
}
```

---

## Testing SCPs Safely

Never attach a new SCP to a production OU without testing. The procedure:

### Step 1: Simulate in the Sandbox OU

Attach the SCP to the Sandbox OU and verify:

```bash
# As a principal in the sandbox account, attempt the action the SCP should deny
aws ec2 run-instances \
  --image-id ami-xxxx \
  --instance-type t3.micro \
  --metadata-options "HttpTokens=optional" \
  --region ca-central-1

# Expected result: AccessDenied (if RequireIMDSv2 is working)
# Also test that legitimate traffic is NOT blocked:
aws ec2 run-instances \
  --image-id ami-xxxx \
  --instance-type t3.micro \
  --metadata-options "HttpTokens=required" \
  --region ca-central-1

# Expected result: Success
```

### Step 2: Use IAM Policy Simulator

The [IAM Policy Simulator](https://policysim.aws.amazon.com/) can evaluate SCPs:

1. Open Policy Simulator in the target account
2. Select a role or user
3. Select the action to test
4. The simulator evaluates SCPs as part of the effective permissions calculation

### Step 3: Use `aws organizations describe-policy`

Verify the SCP content before attaching:

```bash
aws organizations describe-policy \
  --policy-id p-xxxxxxxxxx \
  --query 'Policy.Content' \
  --output text | python3 -m json.tool
```

### Step 4: Monitor CloudTrail After Attachment

After attaching to a non-critical OU, watch CloudTrail for unexpected `AccessDenied` errors:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AccessDenied \
  --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ) \
  --query 'Events[*].{Time:EventTime,User:Username,Error:ErrorCode,Source:EventSource}'
```

---

## ❓ FAQ

### Q: Can an SCP be bypassed by an IAM administrator?

**A:** No. An SCP `Deny` statement cannot be overridden by any IAM policy, including `AdministratorAccess` or the account root user. The only exception is the management account — SCPs do not apply there, and service-linked roles bypass SCPs for service-specific operations.

### Q: What is the maximum size of an SCP?

**A:** Each SCP can be up to [5,120 characters](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_reference_limits.html). You can have up to 5 SCPs attached to any one target (account or OU). Plan your SCP structure to stay within these limits — consolidate related controls into a single policy rather than creating one policy per control.

### Q: Do SCPs apply to AWS services acting on my behalf (e.g., CloudFormation creating resources)?

**A:** It depends. When CloudFormation creates resources on your behalf, it acts under your IAM session's permissions and is subject to SCPs. However, some services use service-linked roles or act via `aws:ViaAWSService` context, which may bypass certain condition-key-based denies. Always test SCP interactions with key AWS services before deploying to production.

### Q: How do I audit which SCPs are attached to which OUs?

**A:** Use the AWS CLI:

```bash
# List all SCPs in the organisation
aws organizations list-policies --filter SERVICE_CONTROL_POLICY

# List SCPs attached to a specific OU
aws organizations list-policies-for-target \
  --target-id ou-xxxx-xxxxxxxx \
  --filter SERVICE_CONTROL_POLICY

# List all targets an SCP is attached to
aws organizations list-targets-for-policy \
  --policy-id p-xxxxxxxxxx
```

### Q: Can I use SCPs to restrict access to specific S3 buckets by name?

**A:** Yes, with caution. SCPs support resource ARNs, so you can write `"Resource": "arn:aws:s3:::my-sensitive-bucket/*"` in a deny statement. However, SCPs cannot enforce *positive* access to specific resources — they can only deny. Use a combination of SCP denies and bucket policies for comprehensive S3 access control.

### Q: What happens if an SCP accidentally blocks a critical service?

**A:** Fix it quickly from the management account. Only the management account can modify and detach SCPs — member accounts cannot. The management account is exempt from SCPs itself, so its access to the Organizations API is never blocked. Use a `terraform plan` preview before every SCP change to confirm the impact.

---

## AWS Documentation Links

- [Service Control Policies Reference](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html)
- [SCP Syntax Reference](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps_syntax.html)
- [AWS Organizations Policy Limits](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_reference_limits.html)
- [Example SCPs from AWS](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps_examples.html)
- [IAM Policy Simulator](https://policysim.aws.amazon.com/)
- [Effective Permissions Reference](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html)
