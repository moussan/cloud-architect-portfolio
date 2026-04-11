# VPC Design Deep Dive

**Author:** Moussa El Najmi, Senior AWS Solutions Architect  
**Scope:** Production VPC architecture — subnets, NACLs, endpoints, IPv6, sharing

---

## Table of Contents

1. [The 3-Tier Subnet Model](#the-3-tier-subnet-model)
2. [Subnet Sizing Calculations](#subnet-sizing-calculations)
3. [NACL vs Security Group Decision Matrix](#nacl-vs-security-group-decision-matrix)
4. [VPC Endpoints](#vpc-endpoints)
5. [PrivateLink Pattern](#privatelink-pattern)
6. [IPv6 Considerations](#ipv6-considerations)
7. [VPC Sharing (Resource Access Manager)](#vpc-sharing-resource-access-manager)
8. [FAQ](#faq)

---

## The 3-Tier Subnet Model

Every production VPC follows a three-tier subnet model. Each tier has distinct connectivity, security posture, and intended workload types.

```
VPC (10.1.0.0/16)
│
├── Public Tier      (/24 × 3 AZs)   → IGW route exists. For external-facing resources.
│   ├── 10.1.0.0/24   (AZ-a)
│   ├── 10.1.1.0/24   (AZ-b)
│   └── 10.1.2.0/24   (AZ-c)
│
├── Private Tier     (/24 × 3 AZs)   → Outbound internet via NAT GW or TGW. No inbound internet.
│   ├── 10.1.10.0/24  (AZ-a)
│   ├── 10.1.11.0/24  (AZ-b)
│   └── 10.1.12.0/24  (AZ-c)
│
└── Data Tier        (/24 × 3 AZs)   → No internet route at all. RFC 1918 only.
    ├── 10.1.20.0/24  (AZ-a)
    ├── 10.1.21.0/24  (AZ-b)
    └── 10.1.22.0/24  (AZ-c)
```

### Tier Characteristics

| Tier | Internet Inbound | Internet Outbound | RFC 1918 Reachability | Typical resources |
|---|---|---|---|---|
| **Public** | Yes (via IGW) | Yes (via IGW) | Full | ALB, NLB, NAT GW, Bastion (deprecated), WAF-fronted endpoints |
| **Private** | No | Yes (via NAT GW or TGW) | Full | EC2, EKS nodes, ECS, Lambda, internal ALB |
| **Data** | No | No | RFC 1918 only | RDS, Aurora, ElastiCache, MSK, OpenSearch, Redshift |

> **Why a data tier with no internet route instead of just Security Groups?**
> Security Groups are per-resource access controls. They are effective, but they are also configurable by anyone with IAM access to EC2 or RDS in that account. A misconfigured Security Group rule (`0.0.0.0/0` on port 3306) on a database is a human error away at all times. Removing the route entirely means there is **no network path for exfiltration** regardless of Security Group state. Defense in depth: route table controls intent at the network level, Security Groups control intent at the application level.

### What Goes in Each Tier

**Public tier workloads:**
- Application Load Balancers (internet-facing)
- Network Load Balancers (internet-facing)
- NAT Gateways (one per AZ)
- API Gateway VPC links (when terminating in VPC)
- Jump servers (use Session Manager instead — avoid bastions)

**Private tier workloads:**
- EC2 instances (all application servers)
- EKS node groups and Fargate pods
- ECS tasks
- Lambda functions (VPC-attached)
- Internal Application Load Balancers
- CodeBuild VPC projects
- AWS Glue VPC connections

**Data tier workloads:**
- RDS and Aurora (all DB engines)
- ElastiCache (Redis, Memcached)
- MSK (Managed Streaming for Kafka)
- OpenSearch Service domains
- Redshift clusters
- Amazon MQ
- DMS Replication instances

---

## Subnet Sizing Calculations

### The Math: How Many Usable IPs per CIDR?

```
/24 subnet → 256 total addresses
  - Network address (.0) = 1 reserved
  - VPC router (.1) = 1 reserved by AWS
  - DNS resolver (.2) = 1 reserved by AWS
  - Future use (.3) = 1 reserved by AWS
  - Broadcast (.255) = 1 reserved
  = 251 usable IPs

/23 subnet → 512 total addresses → 507 usable
/22 subnet → 1,024 total addresses → 1,019 usable
/21 subnet → 2,048 total addresses → 2,043 usable
/20 subnet → 4,096 total addresses → 4,091 usable
```

### Standard Workload Sizing

| Workload | IPs consumed per instance | Recommended subnet size | Notes |
|---|---|---|---|
| EC2 instance | 1 per ENI (multiple ENIs possible) | /24 (251 IPs) | Covers ~200 instances per AZ |
| RDS Multi-AZ | 1 per AZ | /24 (251 IPs) | Overkill for databases, but consistent |
| NAT Gateway | 1 | /24 (251 IPs) | Only 1 IP used; reserve space for expansion |
| ALB | 8 minimum, scales with traffic | /27 (27 IPs) | Use /24 if ALB may scale large |

### EKS Subnet Sizing — The Special Case

EKS with VPC CNI assigns **one VPC IP per pod** (without prefix delegation). Pod density is determined by the number of ENIs and IPs per ENI on the instance type:

```
Instance: m5.2xlarge
  Max ENIs: 4
  IPs per ENI: 15
  Max pods (VPC CNI): (4-1) × (15-1) = 42 pods   ← leaves 1 ENI for node itself

Instance: m5.8xlarge
  Max ENIs: 8
  IPs per ENI: 30
  Max pods: (8-1) × (30-1) = 203 pods

Node group: 10 × m5.8xlarge = 2,030 pod IPs required
```

**A /24 (251 IPs) is insufficient for 10 large nodes.**

**Solution 1: Larger subnets**

```
For 20 m5.8xlarge nodes in one AZ:
  20 × 203 = 4,060 pod IPs + 20 node IPs = 4,080 total
  Need at least: /20 (4,091 IPs) per AZ for EKS nodes
```

**Solution 2: Prefix Delegation (recommended)**

With `ENABLE_PREFIX_DELEGATION=true` on the VPC CNI:
- Each ENI gets a `/28` prefix (16 IPs) instead of individual IPs
- m5.8xlarge: 7 ENIs × 15 prefixes × 16 IPs = 1,680 pod IPs per node
- Each node consumes only **7-15 subnet IPs** (one per prefix) instead of 200+
- **A /24 subnet can support 15+ large nodes** with prefix delegation

```bash
# Enable prefix delegation on existing EKS cluster
kubectl set env daemonset aws-node \
  ENABLE_PREFIX_DELEGATION=true \
  WARM_PREFIX_TARGET=1 \
  -n kube-system
```

> **Why is EKS IP planning so different from everything else?**
> EC2, RDS, Lambda — all consume a predictable number of IPs (1-4 per resource). EKS with VPC CNI breaks this assumption because pods are ephemeral, densely packed, and all get VPC IPs. A node that runs 200 pods uses 200+ IPs. Undersized subnets trigger `failed to allocate IP` errors in the node agent, pods stuck in `ContainerCreating`, and SRE pages at 3 AM. Always model EKS IP consumption before sizing subnets.

---

## NACL vs Security Group Decision Matrix

Both NACLs and Security Groups are firewall controls, but they operate differently and are not substitutes.

### Core Differences

| Property | NACL | Security Group |
|---|---|---|
| **Level** | Subnet-level | ENI (instance) level |
| **Statefulness** | Stateless — must allow inbound AND outbound separately | Stateful — return traffic auto-allowed |
| **Rule evaluation** | In order by rule number, first match wins | All rules evaluated, most permissive wins |
| **Allow/Deny** | Can deny explicitly | Can only allow (deny by default if no match) |
| **Scope** | Applies to all resources in subnet | Attached per-resource |
| **Rule limit** | 20 inbound + 20 outbound per NACL (soft limit 40) | 60 inbound + 60 outbound per SG |
| **Cross-SG reference** | Cannot reference SG IDs | Can reference other SG IDs |

### When to Use NACLs

NACLs are the right control when:

1. **Blocking a known-bad IP/CIDR for the entire subnet** — faster to put in NACL than updating 50 Security Groups
2. **Enforcing subnet-level segmentation between tiers** — NACL on data subnet blocking `0.0.0.0/0` ensures even a misconfigured Security Group cannot create an internet path
3. **Compliance requirement** for explicit deny rules at network layer
4. **Emergency response** — NACLs can be updated without touching instances (stateless, immediate effect)

### When to Use Security Groups

Security Groups are the right control when:

1. **Application-layer port access** — "Web servers can reach DB on port 5432"
2. **Cross-resource references** — "Allow traffic from sg-webservers to sg-database" (works across AZs, auto-resolves IPs)
3. **Instance-level granularity** — different instances in same subnet need different rules
4. **Zero-trust microsegmentation** — each microservice has its own SG

### Decision Matrix

| Scenario | Recommended Control | Reason |
|---|---|---|
| Block all internet → data subnet | **NACL** | Subnet-wide, cannot be overridden by SG misconfig |
| Allow app server → DB port 5432 | **Security Group** | Instance-level, SG-to-SG reference cleaner than CIDRs |
| Emergency: block a DDoS source IP | **NACL** | Faster, subnet-wide, no instance restart needed |
| Microservice A → Microservice B | **Security Group** | SG reference; doesn't break when IPs change |
| Block all traffic from another subnet | **NACL + SG** | Belt-and-suspenders for high-sensitivity boundaries |
| Allow return traffic for established TCP | **Security Group** | Stateful — don't use NACL (requires outbound ephemeral ports rule) |

### NACL Ephemeral Port Trap

If you use NACLs, you MUST allow **ephemeral ports** (1024-65535) for return traffic:

```
# Required outbound rule on private subnet NACL to allow TCP responses:
Rule 100: ALLOW TCP 0.0.0.0/0 port 1024-65535 OUTBOUND
# Without this, any TCP response from the private subnet is dropped by the NACL.
```

This is the most common NACL configuration error — it causes intermittent TCP failures that are hard to diagnose because the connection appears to establish but data transfer fails.

---

## VPC Endpoints

VPC Endpoints keep traffic to AWS services private (no internet traversal) and eliminate NAT Gateway charges for those services.

### Gateway Endpoints (Free)

> **Why Gateway endpoints are always on.** They are free, require no ENI, and reduce NAT Gateway costs by keeping S3/DynamoDB traffic on AWS's internal network.

| Service | Endpoint type | Enable? | Reason |
|---|---|---|---|
| **Amazon S3** | Gateway | Always | All S3 traffic stays private; eliminates NAT charges for S3 |
| **Amazon DynamoDB** | Gateway | Always | Same rationale |

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.data.id]
}
```

### Interface Endpoints (Cost: ~$7.50/AZ/month)

Interface endpoints create ENIs in your subnets. Cost: `$0.01/hr per AZ + $0.01/GB`. For 3 AZs: ~$21.60/month per endpoint.

**Always enable (high ROI):**

| Service | Why it's critical |
|---|---|
| **SSM** (`ssm`, `ssmmessages`, `ec2messages`) | Enables Session Manager — eliminates bastion hosts entirely. Biggest operational win. |
| **ECR** (`ecr.api`, `ecr.dkr`) | EKS/ECS pulls container images. Without endpoints, all image pulls go through NAT GW (expensive at scale). |
| **CloudWatch Logs** (`logs`) | Application logs. Without endpoint, log traffic goes through NAT GW. |
| **STS** (`sts`) | IAM role assumption. Every SDK call uses STS. Without endpoint, STS traffic goes through NAT GW or internet. |
| **Secrets Manager** (`secretsmanager`) | App secrets retrieval. Security requirement to keep off internet. |
| **KMS** (`kms`) | Encryption/decryption operations. High volume for EBS, S3, RDS encryption. |

**Enable based on workload:**

| Service | When to enable |
|---|---|
| **EC2** (`ec2`) | EKS autoscaler, launch templates, describe calls |
| **ELB** (`elasticloadbalancing`) | EKS AWS Load Balancer Controller |
| **Autoscaling** (`autoscaling`) | EKS managed node groups |
| **SNS** (`sns`) | If applications publish to SNS from private subnets |
| **SQS** (`sqs`) | If applications consume from SQS |
| **Lambda** (`lambda`) | If invoking Lambda from private subnet resources |
| **RDS** (`rds`) | RDS control plane calls from applications |
| **CodeArtifact** (`codeartifact.api`, `codeartifact.repositories`) | Private package repositories |

### Cost vs Benefit Analysis

```
Without VPC Endpoints (10 TB/month S3 traffic):
  NAT Gateway data processing: 10,000 GB × $0.045 = $450/month

With S3 Gateway Endpoint (free):
  NAT Gateway charges for S3: $0
  Endpoint cost: $0
  Savings: $450/month

Without ECR endpoints (EKS cluster pulling 1 TB/month):
  NAT Gateway: 1,000 GB × $0.045 = $45/month

With ECR Interface Endpoint (3 AZs):
  Endpoint cost: 3 × $0.01 × 720hr = $21.60/month
  Endpoint data: 1,000 GB × $0.01 = $10/month
  Total: $31.60/month
  Savings: $13.40/month (and traffic stays private)
```

---

## PrivateLink Pattern

[AWS PrivateLink](https://docs.aws.amazon.com/vpc/latest/privatelink/what-is-privatelink.html) enables you to expose a service in one VPC as a private endpoint in another VPC — without routing through the internet, VPC peering, or TGW.

### Use Cases

1. **SaaS provider connectivity** — Connect to third-party services (Datadog, Snowflake, Confluent) over PrivateLink without NAT or internet exposure
2. **Cross-account service exposure** — A platform team's internal API in Account A is accessible from Account B via PrivateLink, with no VPC peering required
3. **Hub-and-spoke alternative for specific services** — High-bandwidth, low-latency service calls between VPCs without going through TGW

### How It Works

```
Consumer VPC (Prod)                    Provider VPC (Shared Services)
                                       
  Interface Endpoint ←───────────────  NLB → Target Group → Service
  (10.1.10.x)                          (Endpoint Service)
  VPC Endpoint ID: vpce-xxxxx
```

**Setup:**

```hcl
# Provider side (Shared Services account)
resource "aws_lb" "service_nlb" {
  name               = "internal-api-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids
}

resource "aws_vpc_endpoint_service" "internal_api" {
  acceptance_required        = true  # Manual approval of each consumer
  network_load_balancer_arns = [aws_lb.service_nlb.arn]
  
  # Allow the Prod account to connect
  allowed_principals = ["arn:aws:iam::PROD_ACCOUNT_ID:root"]
}

# Consumer side (Prod account)
resource "aws_vpc_endpoint" "internal_api" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.vpce.us-east-1.vpce-svc-XXXXXXXX"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.endpoint_sg.id]
  private_dns_enabled = true
}
```

> **Why PrivateLink instead of VPC peering for service exposure?**
> VPC peering exposes the **entire VPC CIDR** of the provider — the consumer can potentially reach any resource in the provider VPC (subject to Security Groups). PrivateLink exposes **only the specific NLB** and its targets. The consumer cannot see or reach anything else in the provider VPC. This is the principle of least privilege applied at the network topology level.

---

## IPv6 Considerations

### Should You Enable IPv6 in Your VPCs?

IPv6 is no longer optional for enterprise workloads. Consider it when:
- Public-facing services need to support IPv6 clients (IPv6 internet traffic is now ~40% globally)
- EKS 1.21+ supports IPv6 natively (pods get IPv6 addresses)
- Government/regulatory environments mandate IPv6 readiness

### Dual-Stack Architecture

```
VPC
├── IPv4 CIDR: 10.1.0.0/16 (RFC 1918, private)
└── IPv6 CIDR: 2600:1f18:xxxx::/56 (AWS-assigned, globally routable)

Subnets: Each subnet gets a /64 from the VPC's /56
  Public subnet: dual-stack, both IPv4 and IPv6
  Private subnet: dual-stack — outbound IPv6 via Egress-only IGW
  Data subnet: IPv4 only recommended (simplest for databases)
```

### IPv6 Key Differences from IPv4

| Aspect | IPv4 | IPv6 |
|---|---|---|
| Outbound-only internet | NAT Gateway | Egress-only Internet Gateway (free) |
| Private addresses | RFC 1918 (NAT) | No NAT — all IPv6 is globally routable. Use SG/NACL for privacy. |
| Address assignment | Manually planned | AWS assigns from Amazon's pool (or you can use your own /56) |
| Cost | NAT GW charges for outbound | Egress-only IGW is free |
| Security Groups | IPv4 rules | Must add separate IPv6 rules (`::0/0` for all IPv6) |

> **Why is IPv6 architecturally different from IPv4?**
> IPv4 private addressing relies on NAT as both an address conservation mechanism AND an implicit security barrier (external hosts cannot initiate connections to RFC 1918 addresses). IPv6 eliminates NAT but also eliminates that implicit barrier — every IPv6 address is globally routable. Security must be explicit: Security Groups and NACLs become the sole access controls. This is architecturally cleaner but requires careful Security Group rule auditing to ensure you haven't accidentally exposed instances via IPv6.

### EKS IPv6 Mode

EKS 1.21+ supports an IPv6 mode where pods receive only IPv6 addresses:
- Pod CIDRs come from the VPC IPv6 allocation — no RFC 1918 exhaustion
- Pods communicate with IPv4 services via NAT64 (handled by VPC CNI automatically)
- Eliminates the EKS IP exhaustion problem entirely for new clusters

```
EKS IPv6 cluster:
  Node IPv4: 10.1.10.x (VPC private subnet)
  Node IPv6: 2600:1f18::x/128
  Pod IPv6: 2600:1f18::/64 per node
  
  Pod → AWS Service (IPv4): VPC CNI NAT64 translation at node level
  Pod → Pod: Direct IPv6 (no NAT, no IP exhaustion)
```

---

## VPC Sharing (Resource Access Manager)

[VPC Sharing](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-sharing.html) allows you to share subnets from an **owner account** with **participant accounts** in the same AWS Organization. Participant accounts deploy resources into the shared subnets.

### Use Case

Instead of a separate VPC per account (with TGW attachments and separate CIDR allocations), VPC sharing puts multiple teams' workloads in the **same VPC but different accounts**:

```
VPC Owner: Network Account
  Shared Subnets → Team A Account: deploys EC2, RDS into subnet-a
  Shared Subnets → Team B Account: deploys Lambda, ECS into subnet-b
```

### VPC Sharing vs Hub-and-Spoke

| Factor | VPC Sharing | Hub-and-Spoke |
|---|---|---|
| **Cost** | Lower (fewer TGW attachments, fewer VPCs) | Higher (TGW + NAT per spoke) |
| **Isolation** | Weaker (same VPC, shared IP space) | Stronger (separate VPCs, TGW routing policy) |
| **Blast radius** | One VPC misconfiguration affects all tenants | VPC-level isolation |
| **Use case** | Platform teams sharing infrastructure, internal tools | Prod/non-prod, strict regulatory boundaries |
| **CIDR planning** | More complex (all teams share the /16) | Simpler (each VPC owns its /16) |

> **When to choose VPC sharing over hub-and-spoke:**
> VPC sharing is best for **platform infrastructure** where multiple teams need access to the same shared services (CI/CD, internal APIs, monitoring) without needing isolated network boundaries. Hub-and-spoke is better when teams have **compliance, regulatory, or security requirements** that mandate network-level isolation between accounts.

---

## FAQ

**Q: How many VPCs should I create per AWS account?**  
A: The rule is: **one VPC per environment per region**, minimum. An account that runs both production and development in the same VPC violates the separation of concerns required by most security frameworks (PCI-DSS, SOC2, HIPAA). Practically: Prod account gets one VPC, Dev account gets one VPC, Shared Services gets one VPC. For multi-region, repeat per region. Using [AWS Control Tower and Landing Zone](https://docs.aws.amazon.com/controltower/latest/userguide/what-is-control-tower.html) automates this account-per-environment structure.

**Q: Can I add a CIDR block to an existing VPC after creation?**  
A: Yes, but with constraints. You can add **secondary CIDR blocks** to an existing VPC (up to 5 CIDRs total). However: (1) you cannot remove the primary CIDR, (2) secondary CIDRs cannot overlap with existing CIDRs, (3) secondary CIDRs must be from the same or different RFC 1918 range. This is useful for adding pod CIDR space for EKS or expanding a running VPC. See [VPC CIDR blocks](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-cidr-blocks.html).

**Q: How do I handle the "5 reserved IPs per subnet" correctly in Terraform count calculations?**  
A: When sizing subnets, subtract 5 from the total address count: `/24 = 256 - 5 = 251 usable`. In Terraform resource definitions, use `cidrsubnet()` which handles the CIDR math. When calculating EKS pod capacity, use `251 × AZ_count - buffer` where buffer accounts for ENI reservation and hot-spare IP management. Enable [prefix delegation](https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html) to make subnet sizing irrelevant for pods.

**Q: Should I use a /24 or /20 for private subnets?**  
A: For most workloads, /24 (251 IPs) per AZ is sufficient and keeps the CIDR table readable. For EKS without prefix delegation, use /22 (1,019 IPs) or /20 (4,091 IPs) per AZ based on your pod density. The key principle: be consistent. Don't mix /24 and /22 without a documented reason — inconsistency creates operational confusion.

**Q: Is it safe to leave the default VPC in each region?**  
A: No. The default VPC has a /20 CIDR (172.31.0.0/20), public subnets with public IPs assigned to instances by default, and an IGW attached. It is a footgun for teams that accidentally deploy to it. Best practice: **delete the default VPC in every region** via your AWS Organizations SCP or account vending automation. See the [default VPC documentation](https://docs.aws.amazon.com/vpc/latest/userguide/default-vpc.html).

**Q: When should I use NACLs vs just Security Groups?**  
A: Use NACLs as a subnet-level defense-in-depth control, not as your primary policy mechanism. Specifically: NACL on data subnets to block `0.0.0.0/0` completely (belt-and-suspenders with Security Groups), NACL for emergency IP blocking during incidents, and NACL for compliance requirements that demand explicit deny rules. For everything else, Security Groups are superior: stateful (no ephemeral port rules needed), SG-to-SG references, per-instance granularity. See the [NACL vs Security Group comparison](https://docs.aws.amazon.com/vpc/latest/userguide/infrastructure-security.html) for the full reference.
