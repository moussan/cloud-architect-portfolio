###############################################################################
# Hub-and-Spoke Network Architecture
# Author: Moussa El Najmi, Senior AWS Solutions Architect
#
# Architecture overview:
#   Hub (Inspection) VPC  ← hosts Network Firewall, NAT GW, centralized egress
#   Prod Spoke VPC        ← production workloads, no direct internet path
#   Dev Spoke VPC         ← development workloads, no direct internet path
#
# Traffic flow (egress):
#   Spoke subnet → TGW → Hub TGW attachment subnet → NFW → NAT GW → IGW → Internet
#
# Traffic flow (ingress):
#   Internet → IGW → ALB (Hub) → TGW → Spoke
#
# Isolation:
#   TGW prod-rt blackholes Dev CIDR
#   TGW nonprod-rt blackholes Prod CIDR
#   NFW enforces stateful L7 policy
#
# Docs:
#   https://docs.aws.amazon.com/vpc/latest/tgw/what-is-transit-gateway.html
#   https://docs.aws.amazon.com/network-firewall/latest/developerguide/what-is-aws-network-firewall.html
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

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "network"
      ManagedBy   = "terraform"
      Owner       = "moussa.elnajmi"
    }
  }
}

###############################################################################
# DATA SOURCES
###############################################################################

# Retrieve the 3 AZs for the chosen region. We use the first 3.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Derive AZ suffix letters (a, b, c) for naming
  az_suffixes = [for az in local.azs : substr(az, length(az) - 1, 1)]
}

###############################################################################
# HUB (INSPECTION) VPC
# This VPC hosts:
#   - AWS Network Firewall endpoints (one per AZ, firewall subnets)
#   - NAT Gateways (one per AZ for HA, in public subnets)
#   - Internet Gateway
#   - TGW attachment subnets (one per AZ, /28 each)
#
# Why a dedicated inspection VPC instead of putting the firewall in a spoke?
#   All inter-spoke and internet traffic must traverse the hub. Having a
#   separate VPC for the hub enforces a clean separation between the network
#   control plane (hub) and workload VPCs (spokes).
###############################################################################

resource "aws_vpc" "hub" {
  cidr_block           = var.hub_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project_name}-hub-vpc" }
}

# Internet Gateway — Hub is the ONLY VPC with direct internet access.
# Spoke VPCs have no IGW. All egress goes: Spoke → TGW → Hub → NAT GW → IGW.
resource "aws_internet_gateway" "hub" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "${var.project_name}-hub-igw" }
}

# --- Hub: Public Subnets (NAT Gateways and ALB live here) ---
# Public subnets have a route to the IGW. They host:
#   - NAT Gateway EIPs (for centralized outbound internet)
#   - Application Load Balancer (centralized ingress, optional)
resource "aws_subnet" "hub_public" {
  count             = 3
  vpc_id            = aws_vpc.hub.id
  cidr_block        = cidrsubnet(var.hub_vpc_cidr, 8, count.index) # /24 each
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project_name}-hub-public-${local.az_suffixes[count.index]}"
    Tier = "public"
  }
}

# --- Hub: Firewall Subnets (NFW endpoints live here) ---
# The Network Firewall endpoint for each AZ resides in its own /24 subnet.
# Route table: all traffic → TGW (for return to spokes) and 0.0.0.0/0 → NAT GW
# (for outbound after inspection).
# WHY separate from public? Firewall subnets must not have a route directly
# to the IGW — traffic must flow: firewall → NAT GW public subnet → IGW.
resource "aws_subnet" "hub_firewall" {
  count             = 3
  vpc_id            = aws_vpc.hub.id
  cidr_block        = cidrsubnet(var.hub_vpc_cidr, 8, count.index + 10) # /24 each, .10.0, .11.0, .12.0
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project_name}-hub-firewall-${local.az_suffixes[count.index]}"
    Tier = "firewall"
  }
}

# --- Hub: TGW Attachment Subnets ---
# These /28 subnets host the TGW ENIs. They get their own route table that
# forces ALL traffic to the NFW endpoint in the same AZ — this is the
# "bump in the wire" that guarantees no traffic bypasses inspection.
# WHY /28? TGW only requires 1 IP per AZ, but AWS recommends /28 minimum.
# 255.0/28, 255.16/28, 255.32/28
resource "aws_subnet" "hub_tgw" {
  count             = 3
  vpc_id            = aws_vpc.hub.id
  cidr_block        = cidrsubnet(var.hub_vpc_cidr, 12, 4080 + count.index) # /28 each at .255.0, .255.16, .255.32
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project_name}-hub-tgw-${local.az_suffixes[count.index]}"
    Tier = "tgw-attachment"
  }
}

# --- Elastic IPs for NAT Gateways ---
# One EIP per AZ. These are the fixed outbound IPs to share with third parties.
resource "aws_eip" "hub_nat" {
  count  = 3
  domain = "vpc"
  tags   = { Name = "${var.project_name}-hub-nat-eip-${local.az_suffixes[count.index]}" }

  depends_on = [aws_internet_gateway.hub]
}

# --- NAT Gateways (one per AZ) ---
# WHY one per AZ instead of one total?
#   A single NAT GW is a single point of failure AND creates cross-AZ traffic
#   charges ($0.01/GB) when EC2 instances in AZ-b use NAT GW in AZ-a.
#   One per AZ eliminates cross-AZ charges and provides AZ-level HA.
#   Cost note: ~$97/month for 3 NAT GWs in hourly charges. Justified when
#   replacing N×3 NAT GWs across spoke VPCs.
resource "aws_nat_gateway" "hub" {
  count         = 3
  subnet_id     = aws_subnet.hub_public[count.index].id
  allocation_id = aws_eip.hub_nat[count.index].id

  tags = { Name = "${var.project_name}-hub-nat-${local.az_suffixes[count.index]}" }

  depends_on = [aws_internet_gateway.hub]
}

###############################################################################
# PROD SPOKE VPC
# Production workloads. Three subnet tiers per AZ:
#   Public  (/24) — Reserved for load balancers if needed in future. Currently
#                   no IGW route; traffic to internet goes via TGW → Hub.
#   Private (/24) — EC2, EKS nodes, ECS tasks, Lambda
#   Data    (/24) — RDS, ElastiCache, MSK. No outbound route to internet.
#
# WHY no IGW in spoke VPCs?
#   Spoke VPCs with IGWs could have resources accidentally given public IPs.
#   Removing the IGW makes this impossible — there is no internet path even
#   if an ENI is assigned a public IP. All internet paths are deliberate (TGW).
###############################################################################

resource "aws_vpc" "prod" {
  cidr_block           = var.prod_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project_name}-prod-vpc" }
}

resource "aws_subnet" "prod_public" {
  count             = 3
  vpc_id            = aws_vpc.prod.id
  cidr_block        = cidrsubnet(var.prod_vpc_cidr, 8, count.index)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project_name}-prod-public-${local.az_suffixes[count.index]}"
    Tier = "public"
    # Tag required for EKS to discover and use these subnets for external LBs
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "prod_private" {
  count             = 3
  vpc_id            = aws_vpc.prod.id
  cidr_block        = cidrsubnet(var.prod_vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project_name}-prod-private-${local.az_suffixes[count.index]}"
    Tier = "private"
    # EKS internal LB subnet tagging
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_subnet" "prod_data" {
  count             = 3
  vpc_id            = aws_vpc.prod.id
  cidr_block        = cidrsubnet(var.prod_vpc_cidr, 8, count.index + 20)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project_name}-prod-data-${local.az_suffixes[count.index]}"
    Tier = "data"
  }
}

# TGW attachment subnets for Prod — /28 each
resource "aws_subnet" "prod_tgw" {
  count             = 3
  vpc_id            = aws_vpc.prod.id
  cidr_block        = cidrsubnet(var.prod_vpc_cidr, 12, 4080 + count.index)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project_name}-prod-tgw-${local.az_suffixes[count.index]}"
    Tier = "tgw-attachment"
  }
}

###############################################################################
# DEV SPOKE VPC
# Development workloads. Same three-tier structure as Prod.
# Key difference: TGW route table (nonprod-rt) blackholes Prod CIDR —
# Dev workloads cannot reach Prod even if they know the IP address.
###############################################################################

resource "aws_vpc" "dev" {
  cidr_block           = var.dev_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project_name}-dev-vpc" }
}

resource "aws_subnet" "dev_public" {
  count             = 3
  vpc_id            = aws_vpc.dev.id
  cidr_block        = cidrsubnet(var.dev_vpc_cidr, 8, count.index)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project_name}-dev-public-${local.az_suffixes[count.index]}"
    Tier = "public"
  }
}

resource "aws_subnet" "dev_private" {
  count             = 3
  vpc_id            = aws_vpc.dev.id
  cidr_block        = cidrsubnet(var.dev_vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project_name}-dev-private-${local.az_suffixes[count.index]}"
    Tier = "private"
  }
}

resource "aws_subnet" "dev_data" {
  count             = 3
  vpc_id            = aws_vpc.dev.id
  cidr_block        = cidrsubnet(var.dev_vpc_cidr, 8, count.index + 20)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project_name}-dev-data-${local.az_suffixes[count.index]}"
    Tier = "data"
  }
}

resource "aws_subnet" "dev_tgw" {
  count             = 3
  vpc_id            = aws_vpc.dev.id
  cidr_block        = cidrsubnet(var.dev_vpc_cidr, 12, 4080 + count.index)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project_name}-dev-tgw-${local.az_suffixes[count.index]}"
    Tier = "tgw-attachment"
  }
}

###############################################################################
# TRANSIT GATEWAY
# The central router. All VPCs and on-premises attach to this single TGW.
#
# Key settings:
#   auto_accept_shared_attachments = "enable" — auto-accepts attachments from
#     other accounts in the same Organization (shared via RAM).
#   default_route_table_association = "disable" — we manage route tables
#     manually (one per domain) rather than using TGW's default table.
#   default_route_table_propagation = "disable" — same reason; manual control.
#   dns_support = "enable" — required for DNS resolution across TGW attachments.
#   vpn_ecmp_support = "enable" — if connecting to on-premises via multiple
#     VPN tunnels, ECMP lets TGW use both for load balancing.
#
# Docs: https://docs.aws.amazon.com/vpc/latest/tgw/tgw-transit-gateways.html
###############################################################################

resource "aws_ec2_transit_gateway" "main" {
  description                     = "${var.project_name} Transit Gateway — hub router"
  amazon_side_asn                 = var.tgw_asn
  auto_accept_shared_attachments  = "enable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"

  tags = { Name = "${var.project_name}-tgw" }
}

###############################################################################
# TGW ROUTE TABLES
# One route table per traffic domain. This is the key security control.
#
#   shared-services-rt: Used by the Hub VPC attachment.
#     Sees routes from all other domains (full visibility needed for return
#     routing after firewall inspection).
#
#   prod-rt: Used by Prod VPC attachment.
#     Can reach: Hub, Shared Services, On-Premises.
#     Cannot reach: Dev, Staging (blackhole routes).
#     Default: 0.0.0.0/0 → Hub (centralized egress).
#
#   nonprod-rt: Used by Dev + Staging VPC attachments.
#     Can reach: Hub, Shared Services, On-Premises.
#     Cannot reach: Prod (blackhole route). CRITICAL isolation boundary.
#     Default: 0.0.0.0/0 → Hub (centralized egress).
#
#   inspection-rt: Used when traffic is returning from Hub back to spokes.
#     This is the TGW route table associated with the Hub attachment.
#     Must have propagated routes from ALL spoke VPCs for the return path
#     to work after firewall inspection.
#
# Docs: https://docs.aws.amazon.com/vpc/latest/tgw/tgw-route-tables.html
###############################################################################

resource "aws_ec2_transit_gateway_route_table" "shared_services" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  tags               = { Name = "${var.project_name}-tgw-rt-shared-services" }
}

resource "aws_ec2_transit_gateway_route_table" "prod" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  tags               = { Name = "${var.project_name}-tgw-rt-prod" }
}

resource "aws_ec2_transit_gateway_route_table" "nonprod" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  tags               = { Name = "${var.project_name}-tgw-rt-nonprod" }
}

resource "aws_ec2_transit_gateway_route_table" "inspection" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  tags               = { Name = "${var.project_name}-tgw-rt-inspection" }
}

###############################################################################
# TGW ATTACHMENTS
# One attachment per VPC. Each attachment connects in a specific AZ using
# the dedicated /28 TGW attachment subnet.
#
# appliance_mode_support = "enable" is set on the Hub attachment.
# WHY? When Network Firewall processes traffic, it must see both directions
# of a flow. Appliance mode ensures TGW routes all packets for a given flow
# through the same AZ's attachment — maintaining traffic symmetry required
# for stateful inspection.
# Docs: https://docs.aws.amazon.com/vpc/latest/tgw/tgw-vpc-attachments.html#create-vpc-attachment
###############################################################################

resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.hub.id
  subnet_ids         = aws_subnet.hub_tgw[*].id

  # appliance_mode_support: CRITICAL for firewall traffic symmetry.
  # Without this, TGW may route return packets through a different AZ's
  # attachment, breaking stateful firewall inspection.
  appliance_mode_support = "enable"

  # DNS support allows instances in this VPC to resolve DNS across the TGW
  dns_support = "enable"

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project_name}-tgw-attach-hub" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "prod" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.prod.id
  subnet_ids         = aws_subnet.prod_tgw[*].id

  dns_support = "enable"
  # appliance_mode not needed for spoke VPCs — they are not inspection points

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project_name}-tgw-attach-prod" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "dev" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.dev.id
  subnet_ids         = aws_subnet.dev_tgw[*].id

  dns_support = "enable"

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project_name}-tgw-attach-dev" }
}

###############################################################################
# TGW ROUTE TABLE ASSOCIATIONS
# An attachment can be associated with exactly ONE route table.
# The associated route table determines which routes the attachment USES
# to forward traffic (the "lookup table" for outbound traffic from that VPC).
###############################################################################

# Hub VPC uses the inspection route table
# WHY? The hub needs to route return traffic back to ALL spoke VPCs after
# the firewall has inspected and allowed a packet.
resource "aws_ec2_transit_gateway_route_table_association" "hub" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}

# Prod VPC uses the prod route table (contains blackholes for dev/staging)
resource "aws_ec2_transit_gateway_route_table_association" "prod" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.prod.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.prod.id
}

# Dev VPC uses the nonprod route table (contains blackhole for prod)
resource "aws_ec2_transit_gateway_route_table_association" "dev" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.dev.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.nonprod.id
}

###############################################################################
# TGW ROUTE TABLE PROPAGATIONS
# Propagation automatically adds a route for the VPC's CIDR into the
# specified route table. An attachment can propagate into multiple tables.
#
# Hub propagates into:
#   - inspection-rt (its own table — for direct hub-to-hub routing)
#   - prod-rt (so prod knows how to reach hub for return traffic)
#   - nonprod-rt (so dev knows how to reach hub for return traffic)
#   - shared-services-rt (hub visibility)
#
# Prod propagates into:
#   - prod-rt (its own table)
#   - inspection-rt (hub needs to know how to return to prod after inspection)
#   - shared-services-rt (shared services needs to reach prod)
#   NOT into nonprod-rt (dev should NOT have a route to prod — only blackhole)
#
# Dev propagates into:
#   - nonprod-rt (its own table)
#   - inspection-rt (hub needs to return to dev after inspection)
#   - shared-services-rt
#   NOT into prod-rt (prod should NOT have a route to dev — only blackhole)
###############################################################################

# Hub propagations
resource "aws_ec2_transit_gateway_route_table_propagation" "hub_to_inspection" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "hub_to_prod" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.prod.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "hub_to_nonprod" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.nonprod.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "hub_to_shared" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared_services.id
}

# Prod propagations
resource "aws_ec2_transit_gateway_route_table_propagation" "prod_to_prod" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.prod.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.prod.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "prod_to_inspection" {
  # Critical: Hub must be able to route return traffic back to Prod after inspection
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.prod.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "prod_to_shared" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.prod.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared_services.id
}

# Dev propagations
resource "aws_ec2_transit_gateway_route_table_propagation" "dev_to_nonprod" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.dev.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.nonprod.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "dev_to_inspection" {
  # Critical: Hub must be able to route return traffic back to Dev after inspection
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.dev.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "dev_to_shared" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.dev.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared_services.id
}

###############################################################################
# TGW STATIC ROUTES
#
# Default route for Prod and NonProd domains:
#   0.0.0.0/0 → Hub TGW attachment (centralized internet egress via hub)
#
# Blackhole routes (the security heart of this architecture):
#   Prod-RT:    blackhole Dev CIDR and Dev CIDR — Prod cannot reach non-prod
#   NonProd-RT: blackhole Prod CIDR — Dev/Staging cannot reach Production
#
# WHY explicit blackholes instead of just absent routes?
#   Absent routes cause silent drops with no audit trail. Explicit blackhole
#   routes: (1) document security intent, (2) appear in route table views,
#   (3) are visible in AWS Network Manager topology. If someone adds a
#   propagation by mistake, the more-specific blackhole overrides it.
###############################################################################

# Default route: Prod domain sends all internet traffic to Hub
resource "aws_ec2_transit_gateway_route" "prod_default" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.prod.id
}

# Default route: NonProd domain sends all internet traffic to Hub
resource "aws_ec2_transit_gateway_route" "nonprod_default" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.nonprod.id
}

# BLACKHOLE: Prod-RT blocks Dev VPC CIDR
# WHY: Production workloads must be completely isolated from development.
# A compromised dev instance cannot probe prod subnets.
resource "aws_ec2_transit_gateway_route" "prod_blackhole_dev" {
  destination_cidr_block         = var.dev_vpc_cidr
  blackhole                      = true
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.prod.id
}

# BLACKHOLE: NonProd-RT blocks Prod VPC CIDR — THE critical isolation boundary
# WHY: This is the single most important route in the entire architecture.
# No matter what, a Dev workload cannot reach the Prod VPC. Blackhole is
# evaluated BEFORE any propagated routes, so a misconfiguration in propagation
# cannot accidentally open this path.
resource "aws_ec2_transit_gateway_route" "nonprod_blackhole_prod" {
  destination_cidr_block         = var.prod_vpc_cidr
  blackhole                      = true
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.nonprod.id
}

###############################################################################
# AWS NETWORK FIREWALL
# Deployed across all 3 AZs for HA. Each AZ gets its own firewall endpoint
# (VPC endpoint ID), which is used as a route table target.
#
# Architecture: NFW is "bump in the wire" — traffic arrives from TGW attachment
# subnet, gets inspected, and forwarded to the NAT GW subnet.
#
# Docs: https://docs.aws.amazon.com/network-firewall/latest/developerguide/
###############################################################################

# --- Stateless Rule Group ---
# Evaluates every packet (not connection-aware). Used for high-throughput
# allow/deny at L3/L4 before stateful inspection.
# WHY have a stateless group? Reduces load on the stateful engine for
# obvious allows (e.g., established TCP return traffic) or obvious drops
# (e.g., ICMP from internet to private ranges).
resource "aws_networkfirewall_rule_group" "stateless_allow_return" {
  name     = "${var.project_name}-stateless-allow-return"
  type     = "STATELESS"
  capacity = 100

  rule_group {
    rules_source {
      stateless_rules_and_custom_actions {
        stateless_rule {
          priority = 10
          rule_definition {
            actions = ["aws:pass"]
            match_attributes {
              # Allow TCP return traffic (ACK, RST, FIN) without full stateful inspection
              protocols = [6] # TCP
              tcp_flag {
                flags = ["ACK"]
                masks = ["SYN", "ACK"]
              }
            }
          }
        }
        stateless_rule {
          priority = 20
          rule_definition {
            actions = ["aws:pass"]
            match_attributes {
              protocols = [17] # UDP — allow all UDP (DNS, NTP, etc.)
            }
          }
        }
      }
    }
  }

  tags = { Name = "${var.project_name}-stateless-allow-return" }
}

# --- Stateful Rule Group: Domain Allow List ---
# Allow outbound HTTPS to approved domains only.
# This uses NFW's built-in domain list rule group type — more efficient
# than Suricata TLS SNI rules for large domain lists.
resource "aws_networkfirewall_rule_group" "stateful_domain_allowlist" {
  name     = "${var.project_name}-stateful-domain-allowlist"
  type     = "STATEFUL"
  capacity = 1000

  rule_group {
    rule_variables {
      # Define HOME_NET to match all RFC 1918 spoke CIDRs
      ip_sets {
        key = "HOME_NET"
        ip_set {
          definition = [
            var.prod_vpc_cidr,
            var.dev_vpc_cidr,
          ]
        }
      }
    }

    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["TLS_SNI", "HTTP_HOST"]
        targets = [
          # AWS service endpoints — required for SDK calls, SSM, ECR, etc.
          ".amazonaws.com",
          ".aws.amazon.com",
          # Package managers
          ".pypi.org",
          "pypi.python.org",
          ".npmjs.com",
          ".yarnpkg.com",
          "registry.npmjs.org",
          ".rubygems.org",
          # Container registries
          ".docker.io",
          "registry-1.docker.io",
          ".gcr.io",
          ".ghcr.io",
          # GitHub for CI/CD
          ".github.com",
          ".githubusercontent.com",
          # Add your organization's approved domains here
        ]
      }
    }
  }

  tags = { Name = "${var.project_name}-stateful-domain-allowlist" }
}

# --- Stateful Rule Group: East-West Policy ---
# Controls which spoke VPCs can communicate with each other.
# Uses Suricata-compatible syntax.
resource "aws_networkfirewall_rule_group" "stateful_east_west" {
  name     = "${var.project_name}-stateful-east-west"
  type     = "STATEFUL"
  capacity = 500

  rule_group {
    rules_source {
      # Suricata-compatible rules for east-west traffic control
      # Docs: https://suricata.readthedocs.io/en/suricata-6.0.0/rules/intro.html
      rules_string = <<-SURICATA
        # Allow Prod → Shared Services on approved ports
        pass tcp ${var.prod_vpc_cidr} any -> ${var.hub_vpc_cidr} [443,8443,636,389] (msg:"Allow Prod to SharedSvc"; sid:1001; rev:1;)
        
        # Allow Dev → Shared Services on approved ports  
        pass tcp ${var.dev_vpc_cidr} any -> ${var.hub_vpc_cidr} [443,8443,636,389] (msg:"Allow Dev to SharedSvc"; sid:1002; rev:1;)
        
        # Block ALL Dev → Prod traffic (belt-and-suspenders with TGW blackhole)
        drop ip ${var.dev_vpc_cidr} any -> ${var.prod_vpc_cidr} any (msg:"BLOCK Dev to Prod"; sid:1010; rev:1;)
        
        # Block ALL Prod → Dev traffic
        drop ip ${var.prod_vpc_cidr} any -> ${var.dev_vpc_cidr} any (msg:"BLOCK Prod to Dev"; sid:1011; rev:1;)
        
        # Alert on unexpected protocols (monitoring, not blocking)
        alert icmp any any -> any any (msg:"ICMP detected"; sid:2001; rev:1;)
      SURICATA
    }
  }

  tags = { Name = "${var.project_name}-stateful-east-west" }
}

# --- Firewall Policy ---
# Combines stateless and stateful rule groups. Defines default actions.
resource "aws_networkfirewall_firewall_policy" "main" {
  name = "${var.project_name}-firewall-policy"

  firewall_policy {
    # Default stateless action: forward to stateful engine for further inspection
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateless_rule_group_reference {
      priority     = 10
      resource_arn = aws_networkfirewall_rule_group.stateless_allow_return.arn
    }

    # Stateful engine order: strict order (priority-based) for predictable policy
    # WHY strict_order vs default? Default order is non-deterministic when
    # multiple rule groups could match. Strict order lets you reason about
    # exactly which rule fires.
    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }

    stateful_rule_group_reference {
      priority     = 100
      resource_arn = aws_networkfirewall_rule_group.stateful_east_west.arn
    }

    stateful_rule_group_reference {
      priority     = 200
      resource_arn = aws_networkfirewall_rule_group.stateful_domain_allowlist.arn
    }

    # Default stateful action: drop all traffic not explicitly allowed
    # WHY DROP vs ALERT? In production, unknown traffic should be blocked.
    # For initial deployment, change to ALERT_ESTABLISHED to see what gets
    # dropped before enforcing, then switch to DROP_ESTABLISHED.
    stateful_default_actions = ["aws:drop_established"]
  }

  tags = { Name = "${var.project_name}-firewall-policy" }
}

# --- Network Firewall Resource ---
# Deployed in the firewall subnets across all 3 AZs.
resource "aws_networkfirewall_firewall" "main" {
  name                = "${var.project_name}-network-firewall"
  vpc_id              = aws_vpc.hub.id
  firewall_policy_arn = aws_networkfirewall_firewall_policy.main.arn

  dynamic "subnet_mapping" {
    for_each = aws_subnet.hub_firewall
    content {
      subnet_id = subnet_mapping.value.id
    }
  }

  # delete_protection prevents accidental deletion in production
  delete_protection = var.enable_firewall_delete_protection

  tags = { Name = "${var.project_name}-network-firewall" }
}

# Extract the firewall endpoint IDs per AZ.
# WHY this complex lookup? NFW returns endpoint IDs keyed by subnet ID.
# We need them keyed by AZ index so we can reference them in per-AZ
# route tables.
locals {
  # Map: AZ name → firewall endpoint ID
  nfw_endpoints = {
    for sync_state in aws_networkfirewall_firewall.main.firewall_status[0].sync_states :
    sync_state.availability_zone => sync_state.attachment[0].endpoint_id
  }

  # List indexed by AZ position (0, 1, 2) — used in route table resources
  nfw_endpoint_ids = [
    for az in local.azs : local.nfw_endpoints[az]
  ]
}

###############################################################################
# VPC FLOW LOGS
# Enable for all VPCs. Ship to S3 (Parquet format for cost-efficient Athena
# queries). In production, also ship to CloudWatch Logs for near-real-time
# alerting, but S3 is the long-term analytics store.
#
# WHY ALL traffic type (not REJECT only)?
#   ACCEPT records are needed for behavioral analysis (e.g., detecting unusual
#   traffic patterns, understanding baseline flows). REJECT-only misses the
#   full picture and makes forensics harder.
#
# Docs: https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html
###############################################################################

# IAM role for Flow Logs to write to CloudWatch (used as fallback/realtime)
data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.project_name}-flow-logs-role"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
  tags               = { Name = "${var.project_name}-flow-logs-role" }
}

# Flow Logs for Hub VPC
resource "aws_flow_log" "hub" {
  vpc_id               = aws_vpc.hub.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = "${var.flow_logs_s3_bucket_arn}/hub/"

  destination_options {
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
  }

  tags = { Name = "${var.project_name}-hub-flow-logs" }
}

# Flow Logs for Prod VPC
resource "aws_flow_log" "prod" {
  vpc_id               = aws_vpc.prod.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = "${var.flow_logs_s3_bucket_arn}/prod/"

  destination_options {
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
  }

  tags = { Name = "${var.project_name}-prod-flow-logs" }
}

# Flow Logs for Dev VPC
resource "aws_flow_log" "dev" {
  vpc_id               = aws_vpc.dev.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = "${var.flow_logs_s3_bucket_arn}/dev/"

  destination_options {
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
  }

  tags = { Name = "${var.project_name}-dev-flow-logs" }
}

###############################################################################
# ROUTE TABLES — HUB VPC
#
# The routing logic for the hub VPC is the most complex in the architecture.
# Every subnet tier has a different next hop:
#
#   Public subnets:
#     0.0.0.0/0 → IGW  (for ALB, NAT GW internet access)
#     10.0.0.0/8 → TGW (to reach spokes via return path)
#
#   Firewall subnets (NFW output path):
#     0.0.0.0/0 → NAT GW (same AZ — for internet egress after inspection)
#     10.0.0.0/8 → TGW  (return RFC 1918 traffic to spokes)
#
#   TGW attachment subnets (NFW input path):
#     0.0.0.0/0 → NFW endpoint (same AZ) ← forces ALL traffic through firewall
#     10.0.0.0/8 → NFW endpoint (same AZ) ← east-west also goes through firewall
###############################################################################

# Public subnet route tables — one per AZ for AZ-affine routing
resource "aws_route_table" "hub_public" {
  count  = 3
  vpc_id = aws_vpc.hub.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hub.id
  }

  route {
    # RFC 1918 to TGW — allows Hub ALB to route to spoke VPC target IPs
    cidr_block         = "10.0.0.0/8"
    transit_gateway_id = aws_ec2_transit_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-hub-public-rt-${local.az_suffixes[count.index]}"
  }

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route_table_association" "hub_public" {
  count          = 3
  subnet_id      = aws_subnet.hub_public[count.index].id
  route_table_id = aws_route_table.hub_public[count.index].id
}

# Firewall subnet route tables — one per AZ
# Traffic arriving here has already been inspected by NFW.
# It goes to NAT GW for internet egress, or back to TGW for return to spokes.
resource "aws_route_table" "hub_firewall" {
  count  = 3
  vpc_id = aws_vpc.hub.id

  route {
    # Internet egress: inspected packets go to NAT GW in same AZ
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.hub[count.index].id
  }

  route {
    # Return path: RFC 1918 traffic goes back to TGW → originating spoke
    cidr_block         = "10.0.0.0/8"
    transit_gateway_id = aws_ec2_transit_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-hub-firewall-rt-${local.az_suffixes[count.index]}"
  }

  depends_on = [
    aws_networkfirewall_firewall.main,
    aws_ec2_transit_gateway_vpc_attachment.hub,
  ]
}

resource "aws_route_table_association" "hub_firewall" {
  count          = 3
  subnet_id      = aws_subnet.hub_firewall[count.index].id
  route_table_id = aws_route_table.hub_firewall[count.index].id
}

# TGW Attachment subnet route tables — one per AZ
# THIS IS THE CRITICAL ROUTING STEP.
# All traffic arriving from TGW (from spokes) MUST be sent to the NFW endpoint
# in the same AZ. This is what makes the firewall inspection mandatory.
resource "aws_route_table" "hub_tgw" {
  count  = 3
  vpc_id = aws_vpc.hub.id

  route {
    # All internet-bound traffic from spokes → NFW endpoint for inspection
    cidr_block      = "0.0.0.0/0"
    vpc_endpoint_id = local.nfw_endpoint_ids[count.index]
  }

  route {
    # All east-west RFC 1918 traffic → NFW endpoint for inspection
    cidr_block      = "10.0.0.0/8"
    vpc_endpoint_id = local.nfw_endpoint_ids[count.index]
  }

  tags = {
    Name = "${var.project_name}-hub-tgw-rt-${local.az_suffixes[count.index]}"
  }

  depends_on = [aws_networkfirewall_firewall.main]
}

resource "aws_route_table_association" "hub_tgw" {
  count          = 3
  subnet_id      = aws_subnet.hub_tgw[count.index].id
  route_table_id = aws_route_table.hub_tgw[count.index].id
}

###############################################################################
# ROUTE TABLES — PROD VPC
#
# Private subnets (where workloads live):
#   0.0.0.0/0 → TGW (internet via hub)
#   10.0.0.0/8 → TGW (all RFC 1918 via hub — for shared services, on-prem)
#
# Data subnets (databases, caches):
#   10.0.0.0/8 → TGW (can reach shared services if needed)
#   NO 0.0.0.0/0 route — no internet access from data tier
#   WHY? Data tier isolation is a defense-in-depth control. Even if an
#   attacker compromises an RDS instance, they cannot establish outbound
#   connections to the internet (exfiltration) because there is no route.
###############################################################################

# Prod private subnet route tables (one shared across all 3 AZs is acceptable
# here; for true AZ isolation, create one per AZ as done for hub).
resource "aws_route_table" "prod_private" {
  vpc_id = aws_vpc.prod.id

  route {
    cidr_block         = "0.0.0.0/0"
    transit_gateway_id = aws_ec2_transit_gateway.main.id
  }

  route {
    cidr_block         = "10.0.0.0/8"
    transit_gateway_id = aws_ec2_transit_gateway.main.id
  }

  tags = { Name = "${var.project_name}-prod-private-rt" }

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.prod]
}

resource "aws_route_table_association" "prod_private" {
  count          = 3
  subnet_id      = aws_subnet.prod_private[count.index].id
  route_table_id = aws_route_table.prod_private.id
}

# Prod data subnet route tables — no internet route
resource "aws_route_table" "prod_data" {
  vpc_id = aws_vpc.prod.id

  route {
    # Can reach Shared Services (e.g., Active Directory for RDS IAM auth) via TGW
    cidr_block         = "10.0.0.0/8"
    transit_gateway_id = aws_ec2_transit_gateway.main.id
  }
  # NOTE: Deliberately no 0.0.0.0/0 route. Data tier is isolated from internet.

  tags = { Name = "${var.project_name}-prod-data-rt" }

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.prod]
}

resource "aws_route_table_association" "prod_data" {
  count          = 3
  subnet_id      = aws_subnet.prod_data[count.index].id
  route_table_id = aws_route_table.prod_data.id
}

###############################################################################
# ROUTE TABLES — DEV VPC
# Same structure as Prod. Dev also has no direct internet path —
# all egress goes via TGW → Hub.
###############################################################################

resource "aws_route_table" "dev_private" {
  vpc_id = aws_vpc.dev.id

  route {
    cidr_block         = "0.0.0.0/0"
    transit_gateway_id = aws_ec2_transit_gateway.main.id
  }

  route {
    cidr_block         = "10.0.0.0/8"
    transit_gateway_id = aws_ec2_transit_gateway.main.id
  }

  tags = { Name = "${var.project_name}-dev-private-rt" }

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.dev]
}

resource "aws_route_table_association" "dev_private" {
  count          = 3
  subnet_id      = aws_subnet.dev_private[count.index].id
  route_table_id = aws_route_table.dev_private.id
}

resource "aws_route_table" "dev_data" {
  vpc_id = aws_vpc.dev.id

  route {
    cidr_block         = "10.0.0.0/8"
    transit_gateway_id = aws_ec2_transit_gateway.main.id
  }

  tags = { Name = "${var.project_name}-dev-data-rt" }

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.dev]
}

resource "aws_route_table_association" "dev_data" {
  count          = 3
  subnet_id      = aws_subnet.dev_data[count.index].id
  route_table_id = aws_route_table.dev_data.id
}
