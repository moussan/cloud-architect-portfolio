# Compute Architecture

> **Reference implementation:** EC2 Auto Scaling Group with mixed Spot/On-Demand, ALB, Session Manager access, and IMDSv2 enforcement.

---

## Table of Contents

1. [Launch Templates vs Launch Configurations](#launch-templates-vs-launch-configurations)
2. [Auto Scaling Group Policies](#auto-scaling-group-policies)
3. [Spot Instance Strategy](#spot-instance-strategy)
4. [AMI Strategy](#ami-strategy)
5. [Session Manager vs Bastion Hosts](#session-manager-vs-bastion-hosts)
6. [IMDSv2 Enforcement](#imdsv2-enforcement)
7. [EC2 Image Builder](#ec2-image-builder-pipeline)
8. [FAQ](#-faq)
9. [AWS Documentation Links](#aws-documentation-links)

---

## Launch Templates vs Launch Configurations

> **Rule: Always use Launch Templates. Launch Configurations are legacy and have been deprecated by AWS as of November 2023.**

| Capability | Launch Template | Launch Configuration |
|---|---|---|
| **Versioning** | Yes — maintain multiple versions, reference `$Latest` or `$Default` or specific `$N` | No — immutable, must create new |
| **Mixed Instances Policy** | Yes — Spot + On-Demand mix | No |
| **Capacity Reservations** | Yes | No |
| **Dedicated Hosts** | Yes | No |
| **IMDSv2** | Yes — `http_tokens = "required"` | No — only IMDSv1 |
| **gp3 EBS volumes** | Yes | Limited |
| **T2 unlimited** | Yes | Yes |
| **Instance Refresh** | Yes | No |

The Terraform resource is `aws_launch_template`. Launch Configurations (`aws_launch_configuration`) should be treated as end-of-life.

> **Why Launch Templates specifically?**  
> Mixed instances policy (Spot + On-Demand in the same ASG) requires Launch Templates. Without it, you cannot implement the cost optimizations that make EC2 at scale economical. Instance Refresh (rolling updates without downtime) also requires Launch Templates.

---

## Auto Scaling Group Policies

### Target Tracking Scaling (Recommended)

Track a CloudWatch metric and scale to maintain a target value. AWS manages the scaling math for you.

```hcl
resource "aws_autoscaling_policy" "cpu_target" {
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60.0
  }
}
```

> **Why 60% CPU target, not 80%?**  
> If you target 80% and traffic spikes 25%, you need to scale by 25% before CPU recovers. At 60% you have 33% headroom — a spike can be absorbed while new instances are launching (which takes 3-5 minutes including health check grace period). 60% is the standard production target for CPU. Use ALB `RequestCountPerTarget` for I/O-bound workloads.

**Common predefined metrics:**
- `ASGAverageCPUUtilization` — best for CPU-bound workloads
- `ALBRequestCountPerTarget` — best for web tiers with variable request size
- `ASGAverageNetworkIn` / `ASGAverageNetworkOut` — best for data transfer workloads

### Step Scaling

Scale in defined steps based on CloudWatch alarm thresholds. Use when you need precise control over scaling behavior at different load levels:

```hcl
# Scale out: 2 instances when CPU 70-90%, 4 instances when CPU > 90%
resource "aws_autoscaling_policy" "scale_out" {
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"

  step_adjustment {
    scaling_adjustment          = 2
    metric_interval_lower_bound = 0
    metric_interval_upper_bound = 20  # 70-90% CPU
  }

  step_adjustment {
    scaling_adjustment          = 4
    metric_interval_lower_bound = 20  # > 90% CPU
  }
}
```

### Scheduled Scaling

Pre-scale for known traffic patterns (business hours, end-of-month processing, marketing campaigns):

```hcl
resource "aws_autoscaling_schedule" "business_hours_scale_out" {
  autoscaling_group_name = aws_autoscaling_group.main.name
  scheduled_action_name  = "business-hours-scale-out"
  recurrence             = "0 7 * * MON-FRI"  # 07:00 UTC weekdays
  min_size               = 4
  desired_capacity       = 6
}

resource "aws_autoscaling_schedule" "off_hours_scale_in" {
  autoscaling_group_name = aws_autoscaling_group.main.name
  scheduled_action_name  = "off-hours-scale-in"
  recurrence             = "0 20 * * MON-FRI"
  min_size               = 2
  desired_capacity       = 2
}
```

---

## Spot Instance Strategy

Spot Instances can reduce EC2 costs by 60-90% vs On-Demand. The risk is Spot interruption (2-minute notice). The mitigation is a **Mixed Instances Policy**:

```
Mixed Instances Policy
├── On-Demand base: 2 instances  ← always available, handles interruptions
├── On-Demand above base: 0%     ← remaining capacity uses Spot
└── Spot pools: 4 instance types ← spread across types = fewer interruptions
    ├── m6i.large
    ├── m6a.large
    ├── m5.large
    └── c6i.large
```

**Key design decisions:**

1. **Multiple instance families**: If `m6i` Spot capacity is unavailable, the ASG tries `m6a`, `m5`, `c6i`. Diversification is the primary interruption mitigation.

2. **Allocation strategy = `capacity-optimized`**: AWS picks the Spot pool with the most available capacity, which also correlates with lowest interruption frequency.

3. **On-Demand base ≥ 1**: Ensures the application is never entirely on Spot. Even a base of 1 On-Demand instance provides stability during multi-pool Spot interruptions.

4. **Lifecycle hooks + connection draining**: Before an instance terminates (Spot interruption or scale-in), deregister from the load balancer and finish in-flight requests. Set `deregistration_delay` on the target group to match your longest request duration.

> **When NOT to use Spot:**  
> - Stateful workloads that cannot tolerate interruption (databases, job queues with no checkpointing)
> - Long-running batch jobs without checkpoint/resume logic
> - Services requiring <2 minute restart time (Spot 2-minute notice is tight)

---

## AMI Strategy

### Golden AMI vs Runtime Bootstrap

| | Golden AMI | Runtime Bootstrap (User Data) |
|---|---|---|
| **Launch time** | 30-90 seconds (just mount and run) | 3-15 minutes (download, install, configure) |
| **Consistency** | Identical binary on every instance | Depends on package registry availability at launch |
| **Security patching** | Rebuild and re-deploy the AMI | Varies — `yum update` in user data works but is slow |
| **Complexity** | Requires EC2 Image Builder pipeline | Just a bash script |
| **Recommended for** | Production, regulated environments | Dev/test, rapid iteration |

**Hybrid approach (recommended for production):**

1. **Golden AMI layer** — OS, runtime, security agents, CrowdStrike/SSM agent, CloudWatch agent. Rebuild weekly from AWS-managed base AMI.
2. **Thin user data** — Application-specific: pull app version from S3 or Parameter Store, start the systemd service. This part is fast (seconds) and environment-specific.

```bash
#!/bin/bash
# Thin user data — runs on Golden AMI that already has Docker installed
set -euo pipefail

APP_VERSION=$(aws ssm get-parameter \
  --name "/myapp/prod/version" \
  --query 'Parameter.Value' \
  --output text)

aws s3 cp "s3://myapp-artifacts/releases/${APP_VERSION}/app.tar.gz" /tmp/app.tar.gz
# ... start service
```

---

## Session Manager vs Bastion Hosts

> **Rule: Use Session Manager. Bastion hosts are a security liability that Session Manager eliminates entirely.**

| Concern | Bastion Host | Session Manager |
|---|---|---|
| **SSH key management** | Must distribute, rotate, revoke SSH keys | No SSH keys — IAM controls access |
| **Port 22 exposure** | Requires security group allowing 22 inbound | No inbound ports required |
| **Audit trail** | `~/.bash_history` (manipulable) | CloudTrail API logs + session keystroke logging to S3/CloudWatch |
| **Infrastructure cost** | EC2 instance + EIP running 24/7 | No additional cost |
| **MFA enforcement** | Complex to enforce | Native via IAM Condition `aws:MultiFactorAuthPresent` |
| **Access control** | SSH key or AD group | IAM policy per instance, per user, per tag |

Session Manager requires:
1. **SSM Agent** on the instance (pre-installed on Amazon Linux 2023, Ubuntu 20.04+)
2. **IAM Instance Profile** with `AmazonSSMManagedInstanceCore` policy
3. **VPC endpoint for SSM** (optional but recommended — keeps traffic private): `com.amazonaws.region.ssm`, `com.amazonaws.region.ssmmessages`, `com.amazonaws.region.ec2messages`

Restrict who can start a session using IAM conditions:

```json
{
  "Effect": "Allow",
  "Action": "ssm:StartSession",
  "Resource": "arn:aws:ec2:*:*:instance/*",
  "Condition": {
    "StringEquals": {
      "ssm:resourceTag/Environment": "prod"
    },
    "Bool": {
      "aws:MultiFactorAuthPresent": "true"
    }
  }
}
```

---

## IMDSv2 Enforcement

IMDSv1 is vulnerable to SSRF attacks — a misconfigured proxy or web app making server-side requests to `169.254.169.254` can retrieve IAM credentials. IMDSv2 requires a session-oriented token:

```
# IMDSv1 (vulnerable)
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/MyRole

# IMDSv2 (requires PUT first to get a token)
TOKEN=$(curl -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
  http://169.254.169.254/latest/api/token)
curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/MyRole
```

**Enforce IMDSv2 in Launch Template:**

```hcl
metadata_options {
  http_endpoint               = "enabled"
  http_tokens                 = "required"  # IMDSv2 required — blocks IMDSv1
  http_put_response_hop_limit = 1           # Prevents container escapes:
  # hop_limit=1 means only the instance itself can reach IMDS.
  # A request from inside a container that goes through a NAT bridge
  # uses 2 hops and would be rejected.
  # For ECS/Kubernetes, set to 2 if containers need instance credentials.
  instance_metadata_tags      = "enabled"   # Allows reading instance tags from IMDS
}
```

> **Why hop limit = 1?**  
> A containerized workload that has an SSRF vulnerability could still reach `169.254.169.254` if the hop limit allows traversal through the container bridge network. With hop limit = 1, only the bare metal instance can reach IMDS, not anything running in a container on top of it.

---

## EC2 Image Builder Pipeline

EC2 Image Builder automates the golden AMI workflow:

```
┌─────────────────────────────────────────────────────┐
│                   Image Pipeline                     │
│                                                      │
│  Source AMI (Amazon Linux 2023 latest)               │
│       ↓                                              │
│  Build Components (sequential)                       │
│  ├── AWS managed: aws-cli-version-2                 │
│  ├── AWS managed: amazon-cloudwatch-agent           │
│  ├── Custom: install-crowdstrike-falcon             │
│  ├── Custom: harden-os (CIS Level 1)                │
│  └── Custom: install-docker-24                      │
│       ↓                                              │
│  Test Components                                     │
│  ├── Assert: cloudwatch-agent running               │
│  ├── Assert: ssh disabled                           │
│  └── Assert: all packages up to date               │
│       ↓                                              │
│  AMI Distribution                                   │
│  ├── Tag: project, environment, build-date          │
│  ├── Share to: dev account, staging account         │
│  └── Deprecation rule: 90 days                      │
└─────────────────────────────────────────────────────┘
```

Key Terraform resources:
- `aws_imagebuilder_image_pipeline` — trigger schedule (weekly)
- `aws_imagebuilder_image_recipe` — ordered component list
- `aws_imagebuilder_component` — custom scripts
- `aws_imagebuilder_distribution_configuration` — which accounts get the AMI
- `aws_imagebuilder_infrastructure_configuration` — build instance type, SNS notifications

---

## ❓ FAQ

**Q: What instance type family should I use for a general-purpose web application?**

A: For a standard web tier (stateless, bursty CPU), the `m6i` (Intel) or `m6a` (AMD) families at `large` or `xlarge` are the right starting point. They offer the best price-to-performance ratio for general workloads. Avoid `t3`/`t4g` in production — burstable performance is unpredictable under sustained load; CPU credits drain silently and performance collapses. Use `t3`/`t4g` only for dev/test or workloads with genuine low-average, high-peak patterns where credit usage is monitored.

---

**Q: How do I handle session stickiness with an ASG?**

A: Prefer stateless applications — the application tier should hold no session state. Instead, use ElastiCache Redis for session storage. If you have a legacy application that requires stickiness, enable it on the ALB target group with `stickiness { type = "lb_cookie", enabled = true }`. Be aware: sticky sessions reduce the effectiveness of scaling — adding instances doesn't redistribute load from existing sticky users.

---

**Q: How do I roll out a new AMI without downtime?**

A: Use **Instance Refresh** on the ASG:

```hcl
instance_refresh {
  strategy = "Rolling"
  preferences {
    min_healthy_percentage = 90   # Keep 90% of desired capacity healthy during refresh
    instance_warmup        = 300  # 5 minutes for a new instance to stabilize before
                                  # the next batch starts replacing
  }
  triggers = ["launch_template"]  # Automatically starts refresh when LT changes
}
```

Terraform detects the Launch Template change (new AMI ID) and triggers Instance Refresh. Old instances are terminated in batches while healthy replacements are launched. With `min_healthy_percentage = 90`, a 10-instance ASG replaces 1 instance at a time.

---

**Q: When should I use a Placement Group?**

A: Three placement group types, three use cases:
- **Cluster** — pack instances close together on the same hardware rack. Use for HPC, MPI, or anything needing 100Gbps enhanced networking (e.g., distributed ML training). Tradeoff: higher risk of simultaneous hardware failures.
- **Spread** — put each instance on distinct hardware. Use for small groups of critical instances (primary + standby databases) where simultaneous hardware failure would be catastrophic. Limited to 7 instances per AZ.
- **Partition** — groups of instances on distinct hardware partitions. Use for large distributed workloads (HDFS, Kafka, Cassandra) where partial failure is tolerable. Up to 7 partitions per AZ, unlimited instances per partition.

For most web tiers with ASGs across multiple AZs, no placement group is needed — multi-AZ provides sufficient fault isolation.

---

**Q: How do I access an EC2 instance in a private subnet for debugging?**

A: Three options, in order of preference:
1. **Session Manager** — no inbound ports, full audit trail, works from the browser. Requires `AmazonSSMManagedInstanceCore` on the instance profile and either a public route or VPC endpoints for SSM.
2. **EC2 Instance Connect Endpoint** (EIC) — [launched 2023](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/connect-with-ec2-instance-connect-endpoint.html). SSH over AWS infrastructure, no bastion. Supports SSH and RDP. `aws ec2-instance-connect ssh --instance-id i-xxxx`
3. **AWS VPN or Direct Connect + jump box** — for environments that already have network connectivity. Not for new architectures.

Never open port 22 from `0.0.0.0/0`.

---

**Q: What's the difference between an ASG health check type of EC2 vs ELB?**

A: EC2 health checks only check if the instance is running and has a valid system status. They do not know if your application is responding correctly. ELB health checks verify that your application responds to HTTP requests at the configured health check path (e.g., `/health`). Always use `health_check_type = "ELB"` for web applications. An instance whose application has crashed but whose OS is still running will appear healthy to EC2 checks but unhealthy to ELB checks — the ASG will replace it only with ELB-type checking enabled.

---

**Q: How do I handle Spot interruption gracefully?**

A: The [Spot interruption notice](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html) appears in the instance metadata 2 minutes before termination:

```bash
# Poll this endpoint in your application or a sidecar process
curl http://169.254.169.254/latest/meta-data/spot/interruption-action
# Returns "terminate" or "stop" or "hibernate" when interruption is imminent

curl http://169.254.169.254/latest/meta-data/spot/instance-action
# Returns: {"action":"terminate","time":"2024-01-15T17:32:00Z"}
```

Best practices:
- ASG lifecycle hooks + connection draining handle in-flight HTTP requests automatically
- Application-level: implement graceful shutdown (catch SIGTERM, drain work queues)
- Use [Spot Interruption Handler](https://github.com/aws/aws-node-termination-handler) for Kubernetes workloads
- Design for idempotent work — if a Spot task is interrupted, it can restart from the beginning

---

**Q: Should I encrypt EBS root volumes?**

A: Yes, always. Set the account-level default for EBS encryption via AWS Config or the EC2 settings console, and also enforce it explicitly in Launch Templates. Encryption at rest is required by most compliance frameworks (SOC 2, PCI DSS, HIPAA). Performance impact of EBS encryption with KMS is negligible (<1% throughput reduction) on instances with NVMe-based storage.

---

## AWS Documentation Links

- [EC2 Launch Templates](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-launch-templates.html)
- [Auto Scaling Group Mixed Instances Policy](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-mixed-instances-groups.html)
- [Target Tracking Scaling Policies](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html)
- [Instance Refresh](https://docs.aws.amazon.com/autoscaling/ec2/userguide/asg-instance-refresh.html)
- [AWS Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [IMDSv2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)
- [EC2 Instance Connect Endpoint](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/connect-with-ec2-instance-connect-endpoint.html)
- [EC2 Image Builder](https://docs.aws.amazon.com/imagebuilder/latest/userguide/what-is-image-builder.html)
- [Spot Instance Interruptions](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html)
- [ALB Health Checks](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html)
