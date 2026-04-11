# Cloud Architect Portfolio — Moussa El Najmi

### Senior AWS Solutions Architect | IaC | Multi-Account | Security | Hybrid Cloud

[![Terraform Validate](https://github.com/moussan/cloud-architect-portfolio/actions/workflows/terraform-validate.yml/badge.svg)](https://github.com/moussan/cloud-architect-portfolio/actions/workflows/terraform-validate.yml)
[![Terraform Security](https://github.com/moussan/cloud-architect-portfolio/actions/workflows/terraform-security.yml/badge.svg)](https://github.com/moussan/cloud-architect-portfolio/actions/workflows/terraform-security.yml)
[![Terraform Docs](https://github.com/moussan/cloud-architect-portfolio/actions/workflows/terraform-docs.yml/badge.svg)](https://github.com/moussan/cloud-architect-portfolio/actions/workflows/terraform-docs.yml)

---

This portfolio demonstrates production-grade AWS architecture across three interconnected disciplines: multi-account governance, enterprise networking, and infrastructure as code. Every module in this repository reflects patterns used in real enterprise environments — nothing here is a tutorial exercise. The work spans AWS Control Tower landing zones, Transit Gateway hub-and-spoke topologies, Terraform modules with full test coverage, and IAM architectures that meet CIS and NIST compliance baselines. This is the work Moussa El Najmi brings to every engagement in Calgary and beyond: security-first, auditable, and built to last.

---

## Portfolio Map

| Pillar | Focus Areas | Directory |
|--------|-------------|-----------|
| **Governance & Control** | Landing Zones, Control Tower, multi-account strategy, SCPs, IAM Identity Center, guardrails, compliance | [`01-governance/`](./01-governance/) |
| **Networking & Connectivity** | Hub & spoke topology, Transit Gateway, VPC design, CIDR allocation, routing tables, AWS Network Firewall, cross-cloud connectivity | [`02-networking/`](./02-networking/) |
| **IaC & Infrastructure** | Reusable Terraform modules, compute (EC2/EKS/Lambda), storage (S3/EFS), databases (RDS/Aurora/DynamoDB), CI/CD automation | [`03-iac/`](./03-iac/) |

---

## Architecture Philosophy

- **Security is a non-negotiable baseline.** Every resource is built with least-privilege access, encryption at rest and in transit, and audit logging enabled by default. Security is not a layer added after the fact — it is the foundation.
- **IaC or it didn't happen.** Every infrastructure decision is expressed in code, reviewed in a pull request, and applied through a pipeline. Clicking in the console is an anti-pattern in production environments.
- **Every decision has a documented rationale.** Architecture Decision Records (ADRs) accompany every module. Future engineers — and future you — deserve to understand *why*, not just *what*.
- **Least privilege always.** IAM roles are scoped to the minimum permissions required for the task at hand. Wildcard actions and `*` resources are treated as defects.
- **Cost is an architecture concern.** Infracost estimates are generated on every pull request. Reserved capacity, Savings Plans, and right-sizing are first-class design considerations, not afterthoughts.

---

## Prerequisites & Tooling

| Tool | Version | Purpose |
|------|---------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | >= 1.5 | Infrastructure provisioning |
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | Latest | AWS authentication and management |
| [Python](https://www.python.org/downloads/) | 3.11+ | Automation scripts, Lambda runtimes |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Latest stable | EKS cluster management |
| [Terragrunt](https://terragrunt.gruntwork.io/docs/getting-started/install/) | >= 0.50 (optional, recommended) | DRY Terraform orchestration across accounts |
| [tfsec](https://github.com/aquasecurity/tfsec) | Latest | Static security analysis for Terraform |
| [Checkov](https://www.checkov.io/) | Latest | Policy-as-code security scanning |
| [Infracost](https://www.infracost.io/docs/) | Latest | Cost estimation in CI/CD pipelines |

---

## Quick Start

```bash
# Clone the repository
git clone https://github.com/moussan/cloud-architect-portfolio
cd cloud-architect-portfolio

# Start with the governance pillar — it must be bootstrapped first
cd 01-governance/landing-zone/terraform

# Copy and fill in environment-specific values
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your management account ID, email addresses, etc.

# Initialise and plan
terraform init && terraform plan

# Review the plan carefully before applying — this creates AWS accounts
terraform apply
```

> **Why start with governance?**
> The landing zone creates the organizational skeleton (OUs, accounts, SCPs) that every other pillar depends on. Networking and compute modules are deployed *into* the accounts and VPCs that governance provisions. You cannot safely skip this step.

---

## Repository Structure

```
cloud-architect-portfolio/
├── .github/
│   └── workflows/
│       ├── terraform-validate.yml     # Syntax + fmt check on every PR
│       ├── terraform-security.yml     # tfsec + checkov on every PR
│       └── terraform-docs.yml         # Auto-generate module docs
│
├── 01-governance/
│   ├── README.md                      # Governance pillar overview + ADRs
│   ├── landing-zone/
│   │   ├── README.md                  # Landing zone module docs
│   │   └── terraform/
│   │       ├── main.tf                # Org, OUs, accounts, SCPs
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       └── terraform.tfvars.example
│   ├── control-tower/
│   │   └── README.md                  # Control Tower conceptual guide
│   ├── iam/
│   │   ├── README.md                  # IAM enterprise patterns
│   │   └── terraform/
│   │       └── main.tf                # Password policy, Access Analyzer, CloudTrail
│   └── scps/
│       ├── README.md                  # SCP deep dive + 8 production SCPs
│       └── terraform/
│           └── main.tf                # All SCPs as Terraform resources
│
├── 02-networking/
│   ├── README.md
│   ├── transit-gateway/
│   │   └── terraform/
│   ├── vpc-baseline/
│   │   └── terraform/
│   └── network-firewall/
│       └── terraform/
│
├── 03-iac/
│   ├── README.md
│   ├── modules/
│   │   ├── compute/
│   │   ├── storage/
│   │   └── databases/
│   └── examples/
│
└── README.md                          # This file
```

---

## Decision Log

Every pillar and module contains Architecture Decision Records (ADRs) explaining the *why* behind significant design choices. ADRs follow the [MADR format](https://adr.github.io/madr/) and are stored as `docs/adr/` within each pillar, or inline in README files as "Why?" callouts.

If you find yourself asking "why was this done this way?" — the answer is documented. If it isn't, open an issue.

---

## Contact

**Moussa El Najmi** — Senior AWS Solutions Architect, Calgary, AB

- [LinkedIn](https://www.linkedin.com/in/moussan)
- [GitHub](https://github.com/moussan)
- moussan@gmail.com
