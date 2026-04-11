################################################################################
# Compute — EC2 ASG + ALB Reference Implementation
#
# Architecture:
#   Internet → ALB (HTTPS/443) → ASG (mixed Spot/On-Demand)
#                                  └── Session Manager (no bastions)
#
# Security posture:
#   - IMDSv2 required on all instances
#   - EBS volumes encrypted with KMS CMK
#   - Security groups follow least-privilege (ALB→ASG only, no 0.0.0.0 for app)
#   - IAM instance profile grants SSM, CloudWatch, S3 config read only
#   - No inbound SSH; access via Session Manager
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
    key            = "compute/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "myorg-tfstate-lock"
    kms_key_id     = "alias/myorg-tfstate"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = merge(var.tags, {
      ManagedBy   = "terraform"
      Module      = "compute"
      Environment = var.environment
    })
  }
}

################################################################################
# Data Sources
################################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_vpc" "main" {
  id = var.vpc_id
}

data "aws_subnets" "public" {
  filter {
    name   = "subnet-id"
    values = var.public_subnet_ids
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "subnet-id"
    values = var.private_subnet_ids
  }
}

# Reference the ACM certificate for the ALB HTTPS listener
data "aws_acm_certificate" "main" {
  domain   = var.domain_name
  statuses = ["ISSUED"]
  # WHY use a data source here rather than creating the cert?
  # ACM cert creation requires DNS validation, which involves external DNS
  # changes. Separating cert provisioning from compute keeps this module
  # narrowly scoped. The cert is created once; compute is deployed many times.
}

################################################################################
# KMS Key for EBS Encryption
#
# WHY a dedicated CMK for EBS?
# - Root volume contains OS, app binaries, and potentially sensitive data in /tmp
# - CMK allows restricting which IAM roles can create/mount encrypted volumes
# - CloudTrail logs every KMS operation — audit trail for volume access
# - AWS-managed key (aws/ebs) cannot have a custom key policy
################################################################################

resource "aws_kms_key" "ebs" {
  description             = "KMS CMK for EBS volume encryption — ${var.environment}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAccountFullControl"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # EC2 service needs to use the key to encrypt/decrypt volumes
        Sid    = "AllowEC2ServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = [
          "kms:CreateGrant",
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:ReEncrypt*"
        ]
        Resource = "*"
      },
      {
        # The ASG instance role needs decrypt access to read encrypted volumes at boot
        Sid    = "AllowInstanceRoleDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.instance.arn
        }
        Action = [
          "kms:CreateGrant",
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/${var.environment}-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}

################################################################################
# IAM — Instance Profile
#
# WHY this role and not AdministratorAccess?
# The principle of least privilege: the instance needs exactly:
# (1) SSM managed instance core — Session Manager, Patch Manager, Run Command
# (2) CloudWatch agent — push metrics and logs to CloudWatch
# (3) S3 read on a specific prefix — fetch application config at startup
#
# It does NOT need: EC2 describe, IAM actions, RDS access, etc.
# If the instance is compromised, the blast radius is limited to what
# the role can do. Overly permissive instance roles are the primary way
# attackers escalate from SSRF to full AWS account compromise.
################################################################################

resource "aws_iam_role" "instance" {
  name = "${var.environment}-compute-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# AWS managed policy — grants Session Manager, Patch Manager, Inventory
resource "aws_iam_role_policy_attachment" "ssm_managed_instance" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# AWS managed policy — allows CloudWatch agent to push metrics and logs
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Inline policy — S3 read access to the config bucket prefix only
resource "aws_iam_role_policy" "s3_config_read" {
  name = "s3-config-read"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # List operations need the bucket ARN (without trailing slash)
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${var.app_config_bucket}"
        Condition = {
          StringLike = {
            "s3:prefix" = ["config/${var.environment}/*"]
          }
        }
      },
      {
        # Get operations need the object ARN (with wildcard path)
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::${var.app_config_bucket}/config/${var.environment}/*"
      },
      {
        # SSM and CloudWatch agents need to read config from Parameter Store
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.environment}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.environment}-compute-instance-profile"
  role = aws_iam_role.instance.name
}

################################################################################
# Security Groups
#
# Design principle: security groups are stateful — only allow what is needed.
# ALB SG: ingress 443 from internet, egress to ASG SG on app port only
# ASG SG: ingress from ALB SG only, egress HTTPS to VPC endpoints
# No rule allows direct SSH from anywhere.
################################################################################

resource "aws_security_group" "alb" {
  name        = "${var.environment}-alb-sg"
  description = "ALB: inbound HTTPS from internet, outbound to ASG on app port"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.environment}-alb-sg"
  }

  lifecycle {
    create_before_destroy = true
    # WHY create_before_destroy?
    # ASG Launch Template references this SG. If the SG is destroyed first,
    # there's a window where new instances launch with a dangling reference.
    # Creating the new SG before destroying the old one prevents this.
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTPS from internet"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_redirect" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP from internet — redirected to HTTPS by listener rule"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_asg" {
  security_group_id            = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.asg.id
  description                  = "Forward to ASG instances on app port"
  # WHY reference SG ID instead of CIDR?
  # SG-to-SG rules are more secure and more maintainable than CIDR rules.
  # If private subnets are re-CIDRed, this rule does not need updating.
  # AWS evaluates this at the ENI level — only instances in the ASG SG
  # can receive this traffic.
}

resource "aws_security_group" "asg" {
  name        = "${var.environment}-asg-sg"
  description = "ASG instances: inbound from ALB only, outbound HTTPS to VPC endpoints"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.environment}-asg-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "asg_from_alb" {
  security_group_id            = aws_security_group.asg.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.alb.id
  description                  = "App traffic from ALB only"
}

resource "aws_vpc_security_group_egress_rule" "asg_https_out" {
  security_group_id = aws_security_group.asg.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.vpc_cidr
  description       = "HTTPS to VPC endpoints (SSM, S3, CloudWatch)"
  # WHY restrict to VPC CIDR?
  # With VPC endpoints for SSM, S3, and CloudWatch, instances in private subnets
  # do not need internet egress. Traffic stays within the VPC.
  # This prevents compromised instances from exfiltrating data to the internet.
}

################################################################################
# Launch Template
#
# This is the blueprint for every EC2 instance launched by the ASG.
# Every security decision is made here — IMDSv2, EBS encryption, monitoring.
################################################################################

# User data script — minimal bootstrap that runs on top of a Golden AMI
# The Golden AMI already has Docker, CloudWatch agent, and SSM agent installed.
locals {
  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -euo pipefail

    # Log all output to CloudWatch via journald
    exec > >(logger -t user-data -s 2>&1) 2>&1

    echo "=== Bootstrap starting at $(date) ==="
    echo "Instance ID: $(TOKEN=$(curl -s -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' http://169.254.169.254/latest/api/token) && curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)"

    # Fetch application version from Parameter Store
    APP_VERSION=$(aws ssm get-parameter \
      --region ${var.region} \
      --name "/${var.environment}/app/version" \
      --query 'Parameter.Value' \
      --output text)

    echo "Deploying app version: $APP_VERSION"

    # Pull application config from S3
    aws s3 cp \
      "s3://${var.app_config_bucket}/config/${var.environment}/app.env" \
      /etc/app/app.env

    # Reload and start the application service (managed by systemd)
    systemctl daemon-reload
    systemctl enable app.service
    systemctl start app.service

    echo "=== Bootstrap complete at $(date) ==="
  EOT
  )
}

resource "aws_launch_template" "main" {
  name_prefix   = "${var.environment}-compute-"
  image_id      = var.ami_id
  instance_type = var.instance_type # Default; ASG mixed-instances policy overrides with multiple types

  # WHY name_prefix instead of name?
  # name_prefix lets Terraform create a new LT version before destroying the old one
  # during updates. With an exact name, you'd hit naming conflicts during replacement.

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  vpc_security_group_ids = [aws_security_group.asg.id]

  user_data = local.user_data

  # IMDSv2 — required, not optional
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # WHY required? IMDSv1 is exploitable via SSRF. A web app with an
    # open redirect or SSRF vulnerability can be tricked into fetching
    # http://169.254.169.254/latest/meta-data/iam/security-credentials/
    # and returning the instance credentials to an attacker.
    # IMDSv2 requires a PUT call first — browser-based SSRF cannot do PUT.

    http_put_response_hop_limit = 1
    # WHY 1? Prevents container workloads from reaching IMDS.
    # Each network hop (e.g., container bridge → host) decrements the TTL.
    # Set to 2 only if containers explicitly need instance credentials.

    instance_metadata_tags = "enabled"
    # Allows code to read tags from IMDS — useful for service discovery
    # without requiring IAM describe-tags permission.
  }

  # EBS root volume — encrypted with CMK
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.root_volume_size
      volume_type = "gp3"
      # WHY gp3? gp3 delivers 3000 IOPS and 125 MB/s baseline at no extra cost
      # and is 20% cheaper than gp2. gp2 IOPS scale with volume size (which
      # means you had to over-provision size to get IOPS). gp3 decouples them.

      iops                  = 3000 # gp3 baseline — sufficient for most app tiers
      throughput            = 125  # gp3 baseline MB/s
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
      delete_on_termination = true
      # WHY delete_on_termination = true?
      # ASG instances are ephemeral. An instance terminated during scale-in
      # should not leave orphaned encrypted volumes — each costs ~$0.08/GB/month
      # and accumulates over time without cleanup.
    }
  }

  # Enable detailed monitoring (1-minute metrics vs 5-minute default)
  monitoring {
    enabled = true
    # WHY detailed monitoring?
    # 5-minute metrics are insufficient for auto-scaling decisions.
    # A 5x traffic spike that resolves in 4 minutes would never trigger
    # a scale-out policy based on 5-minute averages. Detailed monitoring
    # costs ~$3.50/instance/month and enables responsive auto-scaling.
  }

  # Network interface — no public IP (instances are in private subnets)
  network_interfaces {
    associate_public_ip_address = false
    # WHY no public IP?
    # Instances in private subnets do not need public IPs.
    # Inbound traffic comes from the ALB. Outbound goes through NAT GW or
    # VPC endpoints. A public IP is an unnecessary attack surface.
    delete_on_termination = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.environment}-compute"
      Environment = var.environment
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name        = "${var.environment}-compute-root"
      Environment = var.environment
    }
  }

  lifecycle {
    create_before_destroy = true
    # WHY? When the AMI ID or any setting changes, Terraform creates a new
    # Launch Template version first. The ASG Instance Refresh then migrates
    # instances to the new version. Destroying the old version first would
    # leave running instances with no valid template for replacement.
  }
}

################################################################################
# Application Load Balancer
################################################################################

resource "aws_lb" "main" {
  name               = "${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.environment == "prod" ? true : false
  # WHY conditional deletion protection?
  # Prevents accidental destruction of the production ALB which would
  # immediately cause a production outage. Dev/staging allow deletion
  # for faster teardown cycles.

  drop_invalid_header_fields = true
  # WHY? Prevents HTTP request smuggling attacks by rejecting requests
  # with malformed headers that might exploit backend parser differences.

  access_logs {
    bucket  = var.alb_access_log_bucket
    prefix  = "${var.environment}/alb"
    enabled = true
    # WHY ALB access logs?
    # Request-level logging: client IP, request path, response codes, latency.
    # Essential for: security incident investigation, performance analysis,
    # compliance (who accessed what at what time), and Athena cost analysis.
  }
}

# HTTPS listener — primary traffic path
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  # WHY this policy?
  # Supports TLS 1.2 and 1.3. Disables TLS 1.0/1.1 (both deprecated).
  # The TLS13-1-2 prefix means: TLS 1.3 preferred, TLS 1.2 minimum.
  # PCI DSS 4.0 requires TLS 1.2+ minimum. This policy exceeds that requirement.

  certificate_arn = data.aws_acm_certificate.main.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# HTTP listener — redirect to HTTPS, never serve content on HTTP
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
      # WHY 301 (permanent) instead of 302 (temporary)?
      # 301 tells browsers and crawlers to update their bookmarks and cached URLs.
      # After the first redirect, browsers go directly to HTTPS — fewer requests,
      # better SEO signals.
    }
  }
}

# Target Group — where ALB sends traffic
resource "aws_lb_target_group" "main" {
  name     = "${var.environment}-tg"
  port     = var.app_port
  protocol = "HTTP"
  # WHY HTTP between ALB and instances?
  # The ALB terminates TLS. Traffic from ALB to instances is within the VPC
  # (private subnets, encrypted at the AWS infrastructure layer).
  # End-to-end encryption to the instance (HTTPS backend) adds complexity
  # with minimal security benefit on a private VPC network. Use HTTPS
  # backends only if compliance requires it (e.g., PCI DSS in-scope networks).

  vpc_id      = var.vpc_id
  target_type = "instance"

  deregistration_delay = 30
  # WHY 30 seconds?
  # Gives in-flight requests time to complete before the instance is removed.
  # Match this to your P99 request duration. Most web APIs complete in <30s.
  # Long-running requests (file uploads, reports) may need higher values.

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    matcher             = "200"
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 10
    # WHY these thresholds?
    # 2 healthy = fast recovery detection (30s to become healthy)
    # 3 unhealthy = avoid flapping on transient errors (45s to declare unhealthy)
    # 15s interval is the lowest that doesn't overwhelm the health check endpoint
  }

  stickiness {
    type    = "lb_cookie"
    enabled = false
    # WHY disabled?
    # Sticky sessions tie users to specific instances, reducing horizontal
    # scaling effectiveness. Design applications to be stateless and use
    # ElastiCache for session storage. Enable only for legacy applications
    # that cannot be made stateless.
  }
}

################################################################################
# Auto Scaling Group
################################################################################

resource "aws_autoscaling_group" "main" {
  name_prefix         = "${var.environment}-compute-"
  vpc_zone_identifier = var.private_subnet_ids
  # WHY private subnets?
  # Instances are not internet-facing. ALB handles all inbound traffic.
  # Private subnets + NAT GW for outbound reduces attack surface significantly.

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  health_check_type = "ELB"
  # WHY ELB health checks?
  # EC2 health checks only verify the instance OS is running.
  # ELB health checks verify your application is responding correctly.
  # An instance with a hung process passes EC2 checks but fails ELB checks.

  health_check_grace_period = var.health_check_grace_period
  # WHY grace period?
  # New instances take time to bootstrap (download config, start application).
  # Without a grace period, ELB health checks fail during bootstrap and the
  # ASG immediately terminates the instance — creating an infinite loop.

  target_group_arns = [aws_lb_target_group.main.arn]

  # Lifecycle hook — graceful shutdown before instance termination
  initial_lifecycle_hook {
    name                 = "${var.environment}-termination-hook"
    default_result       = "CONTINUE"
    heartbeat_timeout    = 60
    lifecycle_transition = "autoscaling:EC2_INSTANCE_TERMINATING"
    # WHY a termination hook?
    # Without it, the ASG sends the termination signal immediately after
    # deregistering from the ALB. The deregistration_delay handles in-flight
    # HTTP requests, but this hook allows the instance to finish any async
    # work (flush logs, finish queue tasks) before the OS terminates.
  }

  # Mixed Instances Policy — Spot + On-Demand combination
  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity = var.on_demand_base_capacity
      # WHY an on-demand base?
      # Guarantees a minimum number of always-available instances.
      # If Spot capacity is unavailable across all pools, the application
      # stays running on On-Demand instances.

      on_demand_percentage_above_base_capacity = 0
      # WHY 0%? All capacity above the base uses Spot.
      # This maximizes cost savings. Adjust upward (e.g., 50%) if your
      # workload is sensitive to Spot interruptions.

      spot_allocation_strategy = "capacity-optimized"
      # WHY capacity-optimized?
      # AWS selects the Spot pool with the most spare capacity, which
      # also correlates with the lowest interruption rate. This is
      # better than price-capacity-optimized for production because
      # interruptions are more costly than the marginal price difference.
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.main.id
        version            = "$Latest"
        # WHY $Latest?
        # Instance Refresh manages the rollout of new LT versions.
        # $Latest ensures new instances always use the current version.
        # Do not use $Default — it requires manually updating the default version.
      }

      # Override instance types — diversification is the primary Spot interruption mitigation
      dynamic "override" {
        for_each = var.spot_instance_types
        content {
          instance_type     = override.value
          weighted_capacity = "1"
          # WHY weighted_capacity = 1 for all types?
          # All override types are equivalent in vCPU/memory (all are large).
          # Weighted capacity tells ASG how many "units" each instance represents.
          # Equal weights ensure the ASG considers all types equally.
        }
      }
    }
  }

  # Instance Refresh — rolling updates when Launch Template changes
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 90
      # WHY 90%?
      # For a 10-instance ASG, 90% means replace 1 at a time.
      # For a 20-instance ASG, 90% means replace 2 at a time.
      # Keeps the majority of capacity healthy during rollouts.

      instance_warmup = var.health_check_grace_period
      # WHY equal to grace period?
      # Instance Refresh waits this long before declaring a new instance
      # healthy and starting the next replacement batch. Should match
      # how long an instance takes to be fully ready to serve traffic.
    }
    triggers = ["launch_template"]
    # WHY triggers = launch_template?
    # Automatically starts Instance Refresh when the LT changes
    # (new AMI, new user data, etc.). Without this, the ASG would continue
    # running old instances even after Terraform updates the LT.
  }

  tag {
    key                 = "Name"
    value               = "${var.environment}-compute"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      desired_capacity,
      # WHY ignore desired_capacity?
      # The ASG auto-scales desired_capacity based on CloudWatch alarms.
      # If Terraform manages desired_capacity, every plan after a scaling
      # event would show a diff and try to reset capacity. Ignore it —
      # min_size and max_size are the guardrails; desired is operational.
    ]
  }
}

################################################################################
# Auto Scaling Policies
################################################################################

# Target tracking — CPU at 60%
resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "${var.environment}-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value     = var.cpu_target_value
    disable_scale_in = false
    # WHY scale_in enabled?
    # Target tracking handles scale-in automatically — it removes instances
    # when CPU drops significantly below target. disable_scale_in = true
    # would leave instances running during off-peak hours, wasting money.
  }
}

# ALB request count target tracking — useful when requests are I/O-bound
resource "aws_autoscaling_policy" "alb_request_tracking" {
  name                   = "${var.environment}-alb-request-tracking"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    customized_metric_specification {
      metric_name = "RequestCountPerTarget"
      namespace   = "AWS/ApplicationELB"
      statistic   = "Sum"
      metric_dimension {
        name  = "TargetGroup"
        value = aws_lb_target_group.main.arn_suffix
      }
    }
    target_value = var.alb_requests_per_target
    # WHY two scaling policies?
    # CPU-based scaling catches compute-intensive workloads.
    # Request-count scaling catches I/O-bound workloads where CPU stays low
    # but each instance handles too many concurrent connections.
    # Both run simultaneously — ASG respects the more aggressive one.
  }
}
