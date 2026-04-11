###############################################################################
# Production VPC Module
# Author: Moussa El Najmi, Senior AWS Solutions Architect
#
# Creates a single production-grade VPC with:
#   - 3-tier subnets (public/private/data) across 3 AZs
#   - Internet Gateway
#   - NAT Gateways (one per AZ for HA)
#   - VPC Flow Logs (S3 + Parquet for Athena)
#   - S3 and DynamoDB Gateway Endpoints (free, always on)
#   - SSM Interface Endpoints (Session Manager — no bastion needed)
#   - ECR Endpoints (for EKS/ECS image pulls)
#   - NACLs with defense-in-depth defaults
#   - Default Security Group hardening (remove all rules)
#
# This module is intended to be called by the hub-spoke module for spoke VPCs,
# OR used standalone for simple single-VPC deployments.
#
# Usage:
#   module "prod_vpc" {
#     source          = "./vpc-design/terraform"
#     vpc_name        = "prod"
#     vpc_cidr        = "10.1.0.0/16"
#     enable_nat_gateway = true
#     # ... see variables.tf for all options
#   }
###############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

###############################################################################
# DATA SOURCES
###############################################################################

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs         = slice(data.aws_availability_zones.available.names, 0, 3)
  az_suffixes = [for az in local.azs : substr(az, length(az) - 1, 1)]
  region      = data.aws_region.current.name
}

###############################################################################
# VPC
#
# enable_dns_hostnames = true — required for:
#   - Interface VPC endpoints to create DNS names
#   - EKS to assign DNS names to nodes
#   - RDS to generate endpoint hostnames
#
# enable_dns_support = true — enables the AmazonProvidedDNS resolver at
#   the VPC+2 address (e.g., 10.1.0.2). Required for all DNS within VPC.
###############################################################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.additional_tags, {
    Name        = "${var.vpc_name}-vpc"
    Environment = var.environment
    ManagedBy   = "terraform"
  })
}

###############################################################################
# INTERNET GATEWAY
# Only attach if this VPC needs direct internet access (public subnets).
# If this VPC is a spoke in a hub-and-spoke architecture and uses centralized
# egress, set var.create_igw = false and rely on TGW → Hub NAT GW.
###############################################################################

resource "aws_internet_gateway" "main" {
  count  = var.create_igw ? 1 : 0
  vpc_id = aws_vpc.main.id

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-igw"
  })
}

###############################################################################
# SUBNETS
# Three tiers, three AZs = 9 subnets minimum.
#
# Naming convention: {vpc_name}-{tier}-{az_suffix}
#   Example: prod-private-a, prod-data-b
#
# CIDR calculation using cidrsubnet():
#   Public:  3rd octet 0-2   (10.x.0.0/24, 10.x.1.0/24, 10.x.2.0/24)
#   Private: 3rd octet 10-12 (10.x.10.0/24, 10.x.11.0/24, 10.x.12.0/24)
#   Data:    3rd octet 20-22 (10.x.20.0/24, 10.x.21.0/24, 10.x.22.0/24)
#
# WHY this octet scheme?
#   The tens-digit encodes the tier, the units-digit encodes the AZ.
#   Reading "10.1.11.50" immediately tells you: VPC=1 (prod), tier=private, AZ=b.
#   This self-documenting property dramatically reduces route table reading errors.
###############################################################################

# --- Public Subnets ---
resource "aws_subnet" "public" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index) # .0.0/24, .1.0/24, .2.0/24
  availability_zone = local.azs[count.index]

  # WHY false? Instances in public subnets should NOT get public IPs by default.
  # ALBs, NAT Gateways get their own EIPs explicitly. Setting true would cause
  # every EC2 in this subnet to get a public IP — a common security misconfiguration.
  map_public_ip_on_launch = false

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-public-${local.az_suffixes[count.index]}"
    Tier = "public"
    AZ   = local.azs[count.index]
    # EKS external load balancer discovery tag
    "kubernetes.io/role/elb" = "1"
  })
}

# --- Private Subnets ---
resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10) # .10.0/24, .11.0/24, .12.0/24
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = false

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-private-${local.az_suffixes[count.index]}"
    Tier = "private"
    AZ   = local.azs[count.index]
    # EKS internal load balancer discovery tag
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# --- Data Subnets ---
resource "aws_subnet" "data" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 20) # .20.0/24, .21.0/24, .22.0/24
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = false

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-data-${local.az_suffixes[count.index]}"
    Tier = "data"
    AZ   = local.azs[count.index]
  })
}

###############################################################################
# NAT GATEWAYS
# One per AZ for high availability and to avoid cross-AZ data transfer charges.
#
# Cost note: Each NAT Gateway costs ~$0.045/hr = ~$32.40/month in hourly charges
# (excluding data processing). Three AZs = ~$97.20/month.
#
# Alternative: Use a NAT Instance on Graviton (t4g.small) for ~$5/month at
# very low traffic volumes. See: https://fck-nat.dev/ for a community solution.
# Trade-off: NAT Instance is not managed, requires patching, and single-instance.
# Use NAT Gateway for production where HA is required.
#
# Set var.enable_nat_gateway = false if this is a spoke VPC that routes
# outbound traffic via TGW → Hub NAT GW (centralized egress pattern).
###############################################################################

resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 3 : 0
  domain = "vpc"

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-nat-eip-${local.az_suffixes[count.index]}"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count         = var.enable_nat_gateway ? 3 : 0
  subnet_id     = aws_subnet.public[count.index].id
  allocation_id = aws_eip.nat[count.index].id

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-nat-${local.az_suffixes[count.index]}"
  })

  depends_on = [aws_internet_gateway.main]
}

###############################################################################
# ROUTE TABLES
#
# One route table per tier per AZ for public subnets (AZ-specific NAT GW IDs).
# Shared route table for data subnets (no internet route — identical across AZs).
###############################################################################

# --- Public Route Tables (one per AZ) ---
resource "aws_route_table" "public" {
  count  = 3
  vpc_id = aws_vpc.main.id

  # Route to internet via IGW
  dynamic "route" {
    for_each = var.create_igw ? [1] : []
    content {
      cidr_block = "0.0.0.0/0"
      gateway_id = aws_internet_gateway.main[0].id
    }
  }

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-public-rt-${local.az_suffixes[count.index]}"
    Tier = "public"
  })
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[count.index].id
}

# --- Private Route Tables (one per AZ for AZ-local NAT GW routing) ---
# WHY one per AZ? If using NAT Gateways, you want traffic from AZ-a to use
# NAT GW in AZ-a (no cross-AZ charges). If using TGW for egress, a single
# shared route table is fine (TGW routes are the same for all AZs).
resource "aws_route_table" "private" {
  count  = 3
  vpc_id = aws_vpc.main.id

  # Internet egress: use local NAT GW if enabled, else TGW (for hub-spoke)
  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.main[count.index].id
    }
  }

  dynamic "route" {
    for_each = var.transit_gateway_id != "" ? [1] : []
    content {
      # When using hub-spoke: route all traffic (internet + RFC1918) to TGW
      cidr_block         = "0.0.0.0/0"
      transit_gateway_id = var.transit_gateway_id
    }
  }

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-private-rt-${local.az_suffixes[count.index]}"
    Tier = "private"
  })
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# --- Data Route Table (single shared — no internet route by design) ---
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id

  # Intentionally no 0.0.0.0/0 route.
  # WHY? Data tier is completely isolated from internet.
  # Even if someone adds a Security Group rule allowing 0.0.0.0/0, there
  # is no route to carry the packet. Defense in depth at network layer.

  dynamic "route" {
    for_each = var.transit_gateway_id != "" ? [1] : []
    content {
      # Allow data tier to reach Shared Services (e.g., AD, internal APIs) via TGW
      # but NOT internet (this route only covers RFC 1918 if TGW has proper route tables)
      cidr_block         = "10.0.0.0/8"
      transit_gateway_id = var.transit_gateway_id
    }
  }

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-data-rt"
    Tier = "data"
  })
}

resource "aws_route_table_association" "data" {
  count          = 3
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

###############################################################################
# VPC FLOW LOGS
# Docs: https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html
#
# Configuration choices:
#   traffic_type = "ALL" — captures ACCEPT and REJECT. REJECT-only misses
#     behavioral analysis data needed for security forensics.
#   file_format = "parquet" — 80% smaller than plaintext, 10x faster Athena.
#   per_hour_partition = true — enables time-based partition pruning in Athena.
#   hive_compatible_partitions = true — enables Athena partition projection.
###############################################################################

resource "aws_flow_log" "main" {
  count = var.flow_logs_s3_bucket_arn != "" ? 1 : 0

  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = "${var.flow_logs_s3_bucket_arn}/${var.vpc_name}/"

  destination_options {
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
  }

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-flow-logs"
  })
}

###############################################################################
# S3 GATEWAY ENDPOINT
# Free. Routes S3 traffic through AWS internal network — no NAT GW charges.
# Attaches to all route tables (public, private, data).
#
# WHY attach to data subnet route table?
#   RDS Enhanced Monitoring, database exports to S3, and DMS all generate
#   S3 traffic from the data tier. Without the endpoint, these would fail
#   (data tier has no internet route) or require special NACL rules.
###############################################################################

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    aws_route_table.public[*].id,
    aws_route_table.private[*].id,
    [aws_route_table.data.id],
  )

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-s3-endpoint"
  })
}

###############################################################################
# DYNAMODB GATEWAY ENDPOINT
# Also free. Same rationale as S3 — keeps DynamoDB traffic off the NAT GW.
###############################################################################

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${local.region}.dynamodb"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    aws_route_table.public[*].id,
    aws_route_table.private[*].id,
    [aws_route_table.data.id],
  )

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-dynamodb-endpoint"
  })
}

###############################################################################
# SECURITY GROUP FOR INTERFACE ENDPOINTS
# All interface endpoints share this SG. Allow HTTPS (443) from VPC CIDR.
# WHY HTTPS only? All AWS service APIs use HTTPS. No other protocol needed.
###############################################################################

resource "aws_security_group" "vpc_endpoints" {
  count       = var.create_interface_endpoints ? 1 : 0
  name        = "${var.vpc_name}-vpc-endpoints-sg"
  description = "Allow HTTPS from VPC CIDR to AWS service interface endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-vpc-endpoints-sg"
  })
}

###############################################################################
# SSM INTERFACE ENDPOINTS
# These three endpoints together enable AWS Systems Manager Session Manager —
# a fully managed bastion-free remote access solution.
#
# WHY eliminate bastions?
#   Bastions are attack surface. They need patching, SSH key management,
#   security monitoring, and their own access controls. Session Manager
#   provides audited, IAM-controlled shell access to EC2 instances with
#   zero inbound ports open and full CloudTrail logging of every command.
#
# Required endpoints:
#   ssm           — SSM API (parameter store, patch manager, etc.)
#   ssmmessages   — Session Manager WebSocket tunnel
#   ec2messages   — Run Command, State Manager
#
# Docs: https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-create-vpc.html
###############################################################################

locals {
  ssm_services = ["ssm", "ssmmessages", "ec2messages"]
}

resource "aws_vpc_endpoint" "ssm" {
  for_each = var.create_interface_endpoints ? toset(local.ssm_services) : toset([])

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${local.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true # Allows using standard SDK URLs without code changes

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-${each.key}-endpoint"
  })
}

###############################################################################
# ECR ENDPOINTS
# Required for EKS nodes and ECS tasks to pull container images from ECR
# without going through NAT Gateway (significant cost saving for active clusters).
#
# ecr.api — Control plane API (DescribeImages, GetAuthorizationToken, etc.)
# ecr.dkr — Data plane (actual layer pulls — where the GB charges are)
#
# WHY two separate endpoints?
#   ECR splits API calls (lightweight) from data transfer (heavy).
#   The dkr endpoint is the one that saves money.
#
# Also needed for ECR: com.amazonaws.{region}.s3 (layer data stored in S3)
#   — covered by the S3 Gateway endpoint above.
#
# Docs: https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html
###############################################################################

resource "aws_vpc_endpoint" "ecr_api" {
  count = var.create_interface_endpoints && var.create_ecr_endpoints ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${local.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-ecr-api-endpoint"
  })
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  count = var.create_interface_endpoints && var.create_ecr_endpoints ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${local.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-ecr-dkr-endpoint"
  })
}

###############################################################################
# CLOUDWATCH LOGS ENDPOINT
# Keeps application log traffic off NAT GW. High-volume in active environments.
###############################################################################

resource "aws_vpc_endpoint" "logs" {
  count = var.create_interface_endpoints ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${local.region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-logs-endpoint"
  })
}

###############################################################################
# STS ENDPOINT
# Every AWS SDK call performs an STS AssumeRole. Without this endpoint, all
# STS calls go through NAT GW to the internet. At scale (EKS with IRSA,
# Lambda with execution roles), this is high-frequency and adds latency.
###############################################################################

resource "aws_vpc_endpoint" "sts" {
  count = var.create_interface_endpoints ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${local.region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-sts-endpoint"
  })
}

###############################################################################
# NACLs
# Two NACLs: one for public/private subnets (permissive) and one for data
# subnets (restrictive — no internet in or out).
#
# NACL design principles:
#   1. Allow required traffic explicitly
#   2. Ephemeral ports (1024-65535) MUST be allowed for TCP return traffic
#      because NACLs are stateless
#   3. Default NACL (associated with all new subnets) is too permissive —
#      replace with explicit ones
#
# WHY manage NACLs at all if Security Groups handle access control?
#   Defense in depth. NACLs enforce architectural boundaries at the subnet
#   level that cannot be overridden by Security Group misconfiguration.
###############################################################################

# --- Application NACL (Public + Private subnets) ---
resource "aws_network_acl" "application" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)

  # Inbound rules
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  ingress {
    # Allow return traffic (ephemeral ports) for TCP connections initiated
    # from within the subnet. CRITICAL — without this, all outbound TCP fails.
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  ingress {
    # Allow all intra-VPC traffic (private RFC 1918 space)
    rule_no    = 130
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 0
    to_port    = 0
  }

  # Outbound rules
  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  egress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  egress {
    # Allow ephemeral port responses from subnet (return traffic to clients)
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  egress {
    # Allow all intra-VPC outbound
    rule_no    = 130
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 0
    to_port    = 0
  }

  egress {
    # Allow all to 10.0.0.0/8 (other VPCs via TGW/peering)
    rule_no    = 140
    protocol   = "-1"
    action     = "allow"
    cidr_block = "10.0.0.0/8"
    from_port  = 0
    to_port    = 0
  }

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-application-nacl"
    Tier = "application"
  })
}

# --- Data NACL (Data subnets — highly restrictive) ---
resource "aws_network_acl" "data" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.data[*].id

  # Allow inbound database ports from VPC CIDR only
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 3306 # MySQL / Aurora MySQL
    to_port    = 3306
  }

  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 5432 # PostgreSQL / Aurora PostgreSQL
    to_port    = 5432
  }

  ingress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 6379 # Redis
    to_port    = 6379
  }

  ingress {
    rule_no    = 130
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 9092 # Kafka / MSK
    to_port    = 9092
  }

  ingress {
    # Ephemeral ports for return traffic (db → client)
    rule_no    = 140
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 1024
    to_port    = 65535
  }

  # Outbound: allow responses to VPC CIDR only. NO internet egress.
  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 1024
    to_port    = 65535
  }

  # NOTE: No 0.0.0.0/0 outbound rule. Data tier cannot reach internet.
  # This is the belt-and-suspenders control alongside the missing route.

  tags = merge(var.additional_tags, {
    Name = "${var.vpc_name}-data-nacl"
    Tier = "data"
  })
}

###############################################################################
# DEFAULT SECURITY GROUP HARDENING
# The default Security Group in every VPC allows all inbound traffic from
# itself and all outbound traffic. This is an AWS default that violates
# least-privilege principles.
#
# AWS security best practices and CIS Benchmarks require removing all rules
# from the default SG so it is never accidentally used.
#
# WHY not just delete it? The default SG cannot be deleted — only cleared.
# Every new ENI created without an explicit SG assignment gets the default SG.
# By removing all rules, accidentally-assigned ENIs have no network access,
# which is detectable and correctable.
###############################################################################

resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  # No ingress rules — removes the default "allow from self" rule
  # No egress rules — removes the default "allow all outbound" rule
  # Result: any ENI with only the default SG has zero network access.

  tags = merge(var.additional_tags, {
    Name        = "${var.vpc_name}-default-sg-DO-NOT-USE"
    Description = "Default SG intentionally cleared. See networking standards."
  })
}
