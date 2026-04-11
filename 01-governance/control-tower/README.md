# AWS Control Tower — Conceptual Guide

> **Why read this guide?**
> Control Tower abstracts significant complexity, but that abstraction has limits. Engineers who understand what Control Tower automates — and what it does not — make better decisions about when to use it, when to extend it, and when a DIY approach serves them better. This guide is a practitioner's reference, not a product pitch.

---

## What Control Tower Automates vs. What You Still Configure

Control Tower is not a magic "make my AWS environment enterprise-ready" button. It automates a specific set of tasks at setup time and provides an ongoing management console. Understanding the boundary is critical.

### What Control Tower Automates

| Task | Mechanism |
|------|-----------|
| Creating the management account and Log Archive + Audit accounts | Account vending via internal APIs |
| Enabling AWS Organizations with ALL_FEATURES | Org API calls |
| Creating the Security OU and Sandbox OU | Org API calls |
| Deploying a baseline CloudTrail (organisation-level) | CloudFormation StackSet |
| Deploying AWS Config recorder and delivery channel to each enrolled account | CloudFormation StackSet |
| Enabling mandatory guardrails (as SCPs and Config rules) | SCP API + AWS Config managed rules |
| Creating the AWSControlTowerExecution IAM role in each account | CloudFormation StackSet |
| Providing Account Factory (a Service Catalog product for account vending) | AWS Service Catalog |

### What You Still Configure

| Task | Why Control Tower Does Not Handle It |
|------|--------------------------------------|
| Additional OUs beyond Security and Sandbox | Your org structure is unique; CT cannot know it |
| Custom SCPs | CT only manages guardrail SCPs — your business rules are your responsibility |
| Transit Gateway and networking | Networking is a separate domain |
| IAM Identity Center configuration (permission sets, group assignments) | CT enables Identity Center but does not configure it |
| Workload-specific Config rules | CT deploys baseline Config; application compliance rules are yours |
| Cost anomaly detection and budgets | Out of scope for CT |
| Custom CloudWatch alarms and dashboards | Out of scope for CT |
| Billing contacts, alternate contacts | Account-level configuration |

---

## Account Factory

Account Factory is the Control Tower mechanism for vending new AWS accounts. It is a Service Catalog product that, when launched, creates a new account in your organisation, places it in the specified OU, deploys the CT baseline, and optionally runs a customisation pipeline.

### Manual Account Factory (Console)

The console-based flow suits small organisations or low-volume account creation:

1. Open Control Tower → Account Factory → Enroll account
2. Fill in account name, email, OU, and IAM Identity Center user
3. Click submit — CT creates the account and applies the baseline StackSets
4. Estimated time: 15–30 minutes per account

**Limitations:** No version control, no pull-request review, no idempotency, hard to audit who created which account and why.

### Account Factory for Terraform (AFT)

[AFT](https://docs.aws.amazon.com/controltower/latest/userguide/aft-overview.html) is the production-grade account vending approach. Account requests are expressed as Terraform:

```hcl
# accounts/prod-app-3/main.tf
module "prod_app_3" {
  source = "github.com/aws-ia/terraform-aws-control_tower_account_factory"

  control_tower_parameters = {
    AccountEmail              = "aws+prod-app-3@example.com"
    AccountName               = "prod-app-3"
    ManagedOrganizationalUnit = "Production"
    SSOUserEmail              = "platform-admin@example.com"
    SSOUserFirstName          = "Platform"
    SSOUserLastName           = "Admin"
  }

  account_tags = {
    Environment = "prod"
    Application = "app-3"
    Owner       = "app-team"
  }
}
```

A pull request to add this file triggers an AFT pipeline that creates the account. The PR is the audit trail.

> **Why AFT over console Account Factory?** Git history is the audit trail. Code review catches mistakes before accounts are created. Idempotency means re-running the pipeline does not create duplicate accounts. AFT makes account creation a first-class engineering activity.

---

## Customizations for Control Tower (CfCT)

[CfCT](https://aws.amazon.com/solutions/implementations/customizations-for-aws-control-tower/) allows you to deploy custom CloudFormation stacks and SCPs to specific accounts or OUs automatically when:
- A new account is enrolled
- An existing account is moved to a different OU
- A lifecycle event triggers (e.g., `CreateManagedAccount`)

CfCT is a CodePipeline that reads a `manifest.yaml` from a CodeCommit repository. Example manifest:

```yaml
# manifest.yaml
region: ca-central-1
version: 2021-03-15

organizational_units:
  - name: Production
    core_accounts:
      - name: log-archive
    workload_accounts:
      - name: prod-app-1
        ssm_parameters:
          - name: /cfct/prod-app-1/account-id
            value: $[AccountId]
    customizations:
      - name: prod-security-baseline
        resource_file: templates/prod-security-baseline.yaml
        deploy_method: stack_set
        accounts:
          - all
```

> **Why CfCT?** It bridges the gap between "Control Tower enrolled this account" and "this account has our full baseline applied". Without CfCT, every new account needs manual post-enrolment steps. CfCT automates them.

---

## Control Tower vs. Landing Zone Accelerator (LZA)

Both solve the "enterprise-ready AWS environment" problem but at different scales and complexity levels.

| Factor | Control Tower | Landing Zone Accelerator (LZA) |
|--------|--------------|-------------------------------|
| **Deployment mechanism** | Console + StackSets | CodePipeline + CloudFormation |
| **Target scale** | Small to large enterprise | Large enterprise, government, regulated |
| **Compliance frameworks** | CIS benchmark guardrails | NIST 800-53, CMMC, HIPAA, PCI-DSS baselines built-in |
| **Networking automation** | Manual | Automated VPCs, TGW, centralized firewalls |
| **Customisation model** | CfCT + AFT | YAML configuration files (config.yaml) |
| **AWS managed** | Yes | Partially (open source, you host the pipeline) |
| **Learning curve** | Medium | High |
| **When to choose** | Most enterprise environments | Government, defence, or highly regulated commercial |

> **LZA documentation:** [Landing Zone Accelerator on AWS](https://docs.aws.amazon.com/solutions/latest/landing-zone-accelerator-on-aws/overview.html)

---

## Migration Path: Existing Org → Control Tower

Migrating an existing AWS Organisation to Control Tower is one of the most common and most painful enterprise AWS tasks. The steps below represent the safe path:

### Pre-Migration Checklist

- [ ] Verify no accounts have an existing CloudTrail with the name `aws-controltower-BaselineCloudTrail`
- [ ] Verify no accounts have an existing AWS Config recorder (or be prepared to delete/rename it)
- [ ] Verify the management account does not have existing SCPs that conflict with CT mandatory guardrails
- [ ] Identify which existing accounts need to be enrolled vs. kept outside CT
- [ ] Create IAM Identity Center (if not already enabled) — CT requires it
- [ ] Choose your home region carefully — it cannot be changed after CT setup

### Migration Steps

1. **Enable Control Tower on the management account** (creates Log Archive and Audit accounts, sets up baseline)
2. **Register existing OUs** with Control Tower (OU must not have accounts already — enrol accounts first)
3. **Enrol existing accounts** via Account Factory → Enroll account
4. **Remediate conflicts** — CT will report any resources that conflict with its StackSets; resolve them manually
5. **Apply CfCT customisations** to enrolled accounts to bring them to your baseline
6. **Migrate to AFT** for all future account vending

> **Why is this hard?** Control Tower assumes it owns certain resources (CloudTrail, Config recorder, specific IAM roles). Existing accounts often have resources with the same names but different configurations. The enrolment process detects and surfaces these conflicts, but resolving them requires account-level access to every account being enrolled.

---

## Guardrails Deep Dive

AWS Control Tower guardrails fall into three activation categories:

### Mandatory Guardrails (Always Enabled)

Cannot be disabled. Enforce the minimum baseline that makes Control Tower function:

| Guardrail | Type | What it does |
|-----------|------|-------------|
| Disallow changes to CloudTrail set up by CT | Preventive (SCP) | Prevents tampering with the org-level CloudTrail |
| Disallow deletion of Log Archive | Preventive (SCP) | Prevents deleting the audit log bucket |
| Disallow changes to Config rules set up by CT | Preventive (SCP) | Protects CT's compliance baseline |
| Detect whether MFA for root is enabled | Detective (Config) | Alerts if root MFA is disabled |

### Strongly Recommended Guardrails

Disabled by default but strongly advised for any production environment:

| Guardrail | Type | What it does |
|-----------|------|-------------|
| Detect whether public S3 read access is allowed | Detective (Config) | Flags publicly readable S3 buckets |
| Detect whether public S3 write access is allowed | Detective (Config) | Flags publicly writable S3 buckets |
| Detect whether EBS volumes are encrypted | Detective (Config) | Flags unencrypted EBS volumes |
| Detect whether unrestricted SSH access is allowed | Detective (Config) | Flags security groups with 0.0.0.0/0 on port 22 |
| Detect whether CloudTrail is enabled | Detective (Config) | Flags accounts where CloudTrail is disabled |

### Elective Guardrails

Optional controls for specific compliance requirements:

| Guardrail | Type | Applicable When |
|-----------|------|----------------|
| Disallow internet access for VPC-resident Lambda | Preventive (SCP) | When Lambda must not make outbound internet calls |
| Detect whether RDS snapshots are public | Detective (Config) | Always recommended |
| Require MFA for IAM users | Preventive (SCP) | When IAM users (not Identity Center) are still in use |
| Detect unencrypted RDS instances | Detective (Config) | Always recommended |

---

## ❓ FAQ

### Q: Can I use Control Tower in an existing organisation that already has many accounts?

**A:** Yes, but you must enrol existing accounts one by one via Account Factory. CT does not bulk-enrol accounts. Each account enrolment deploys StackSets and may fail if the account has conflicting resources. Plan for 30–60 minutes per account in a complex environment.

### Q: What is the Control Tower home region and can I change it?

**A:** The home region is where Control Tower's management components (Log Archive S3 bucket, CloudTrail, Config aggregator) are deployed. It is selected during initial CT setup and **cannot be changed** without decommissioning and redeploying CT. Choose it carefully — for Canadian workloads, `ca-central-1` is the correct choice.

### Q: Does Control Tower support AWS GovCloud?

**A:** AWS Control Tower is available in AWS GovCloud (US-East and US-West) but with a different feature set and additional prerequisites. See the [Control Tower GovCloud documentation](https://docs.aws.amazon.com/controltower/latest/userguide/govcloud-limitations.html) for current limitations.

### Q: How does Control Tower interact with existing CloudTrail configurations?

**A:** CT creates an organisation-level CloudTrail named `aws-controltower-BaselineCloudTrail`. If an existing account already has a trail with this name, enrolment will fail. You must either rename or delete the existing trail before enrolment. CT's trail logs to the Log Archive account.

### Q: Can I delete a Control Tower guardrail?

**A:** Mandatory guardrails cannot be deleted or disabled. Strongly recommended and elective guardrails can be disabled per-OU. Disabling a guardrail does not delete its underlying SCP or Config rule immediately — there may be a propagation delay.

### Q: What happens to my environment if I de-commission Control Tower?

**A:** Decommissioning CT removes CT-managed StackSets from enrolled accounts and removes CT's SCPs and guardrails. Your AWS Organisation structure (accounts and OUs) remains intact. You are responsible for replacing the baseline controls (CloudTrail, Config, SCPs) with your own mechanisms before decommissioning. AWS provides a [decommission guide](https://docs.aws.amazon.com/controltower/latest/userguide/decommission-landing-zone.html).

---

## AWS Documentation Links

- [AWS Control Tower Documentation](https://docs.aws.amazon.com/controltower/latest/userguide/what-is-control-tower.html)
- [Account Factory for Terraform (AFT)](https://docs.aws.amazon.com/controltower/latest/userguide/aft-overview.html)
- [Customizations for Control Tower (CfCT)](https://aws.amazon.com/solutions/implementations/customizations-for-aws-control-tower/)
- [Landing Zone Accelerator on AWS](https://docs.aws.amazon.com/solutions/latest/landing-zone-accelerator-on-aws/overview.html)
- [Control Tower Guardrail Reference](https://docs.aws.amazon.com/controltower/latest/userguide/guardrails-reference.html)
- [Enrolling Existing Accounts](https://docs.aws.amazon.com/controltower/latest/userguide/enroll-account.html)
- [Control Tower Decommission Guide](https://docs.aws.amazon.com/controltower/latest/userguide/decommission-landing-zone.html)
