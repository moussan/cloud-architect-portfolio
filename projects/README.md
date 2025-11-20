# Cloud Architect Portfolio – Moussa El Najmi
Senior Cloud Architect | AWS | Hybrid Cloud | IaC | Security Architecture


This repository contains a curated set of hands-on AWS architecture projects that demonstrate my skills as a Senior Cloud Architect:

- Multi-account AWS landing zones
- Hybrid cloud networking (Direct Connect, Transit Gateway, VPN)
- High availability application design
- Serverless & event-driven architectures
- Containerized workloads on EKS
- Data lake & analytics patterns
- Infrastructure as Code (Terraform) and GitOps

---

## 📁 Projects

Each project lives under `projects/<project-name>` with:

- `terraform/` – Infrastructure as Code
- `app/` or `src/` – Application or Lambda code (when relevant)
- `k8s/` – Kubernetes manifests (where relevant)
- `README.md` – Architecture description and usage

### 1. High Availability Web Application (ALB + ASG + EC2)

**Path:** `projects/01-ha-web-app/`  
**Highlights:**

- VPC with public/private subnets in 2 AZs  
- Application Load Balancer in public subnets  
- Auto Scaling Group of EC2 instances in private subnets  
- Security Groups with least privilege

---

### 2. Serverless Event-Driven Pipeline (S3 → Lambda → DynamoDB → SNS)

**Path:** `projects/02-serverless-pipeline/`  
**Highlights:**

- S3 bucket for ingestion  
- Lambda function for metadata extraction  
- DynamoDB table for event storage  
- SNS topic for notifications

---

### 3. AWS Landing Zone (Multi-Account + SCPs)

**Path:** `projects/03-landing-zone/`  
**Highlights:**

- AWS Organizations and Organizational Units  
- Example accounts (Security, Shared Services, Prod, Dev)  
- Service Control Policies (SCPs) for guardrails

---

### 4. Containerized App Deployment on EKS

**Path:** `projects/04-eks-application-deployment/`  
**Highlights:**

- EKS cluster via Terraform module (optional)  
- Kubernetes Deployment + Service manifests  
- Example of GitOps-friendly structure

---

### 5. Hybrid Cloud Architecture (DX + TGW + VPN)

**Path:** `projects/05-hybrid-cloud-architecture/`  
**Highlights:**

- Transit Gateway as the core routing hub  
- Example Direct Connect Gateway + TGW attachment  
- Site-to-site VPN for backup connectivity  
- Multiple VPC attachments (Prod, Shared Services)

---

### 6. Data Lake & Analytics (S3 + Glue + Athena)

**Path:** `projects/06-data-lake/`  
**Highlights:**

- Raw / processed S3 buckets  
- Glue Database + Crawler  
- Athena Workgroup for querying

---

## 🛠 Tooling & Conventions

- **Terraform**: used for all infrastructure definitions  
- **Python**: used for Lambda functions  
- **YAML**: used for Kubernetes manifests & GitHub Actions workflows

You will need:

- Terraform ≥ 1.5  
- AWS CLI configured  
- kubectl (for the EKS demo)  
- Python 3.11+ (for Lambda packaging)

---

## 🚀 How to Use

For any project:

```bash
cd projects/01-ha-web-app/terraform

terraform init
terraform plan
terraform apply
```

Tear down when done:

```bash
terraform destroy
```
