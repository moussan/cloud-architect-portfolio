###############################################################################
# Variables — Hub-and-Spoke Network Architecture
# Author: Moussa El Najmi, Senior AWS Solutions Architect
#
# All variables have sensible defaults suitable for a standard enterprise
# deployment. Override in terraform.tfvars for environment-specific values.
###############################################################################

###############################################################################
# GENERAL
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy all resources into. Choose a region with at least 3 AZs (all commercial regions qualify). For multi-region deployments, instantiate this module once per region."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "Must be a valid AWS region name (e.g., us-east-1, eu-west-1)."
  }
}

variable "project_name" {
  description = "Short project or organization name used as a prefix for all resource names and tags. Keep under 20 characters to avoid hitting AWS name length limits on compound resource names. Example: 'acme-net', 'corp-infra'."
  type        = string
  default     = "enterprise"

  validation {
    condition     = length(var.project_name) <= 20 && can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Must be lowercase alphanumeric with hyphens, max 20 characters."
  }
}

###############################################################################
# VPC CIDR BLOCKS
# These CIDRs must be:
#   1. Within RFC 1918 private address space (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
#   2. Non-overlapping with each other
#   3. Non-overlapping with on-premises CIDR ranges
#   4. /16 each — large enough for future subnets and EKS pod CIDRs
#
# The cidrsubnet() calls in main.tf assume a /16 parent for each VPC.
# If you change to /17 or smaller, update the subnet calculations.
###############################################################################

variable "hub_vpc_cidr" {
  description = "CIDR block for the Hub (Inspection) VPC. This VPC hosts the Network Firewall, NAT Gateways, and TGW attachment subnets. Recommended: a /16 from your enterprise allocation. Default uses 10.0.0.0/16 which leaves 10.1-10.255.x.x for spokes."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.hub_vpc_cidr, 0)) && tonumber(split("/", var.hub_vpc_cidr)[1]) <= 16
    error_message = "Must be a valid CIDR block of /16 or larger (smaller prefix number)."
  }
}

variable "prod_vpc_cidr" {
  description = "CIDR block for the Production spoke VPC. Must not overlap with hub_vpc_cidr, dev_vpc_cidr, or on-premises ranges. Workloads in this VPC are isolated from non-production via TGW blackhole routes."
  type        = string
  default     = "10.1.0.0/16"

  validation {
    condition     = can(cidrhost(var.prod_vpc_cidr, 0)) && tonumber(split("/", var.prod_vpc_cidr)[1]) <= 16
    error_message = "Must be a valid CIDR block of /16 or larger."
  }
}

variable "dev_vpc_cidr" {
  description = "CIDR block for the Development spoke VPC. Isolated from Production by TGW blackhole routes in both the prod-rt and nonprod-rt route tables. Must not overlap with other VPC CIDRs."
  type        = string
  default     = "10.2.0.0/16"

  validation {
    condition     = can(cidrhost(var.dev_vpc_cidr, 0)) && tonumber(split("/", var.dev_vpc_cidr)[1]) <= 16
    error_message = "Must be a valid CIDR block of /16 or larger."
  }
}

###############################################################################
# TRANSIT GATEWAY
###############################################################################

variable "tgw_asn" {
  description = "BGP ASN for the Transit Gateway. Used for BGP peering with Direct Connect and VPN attachments. Must be in the private ASN range: 64512-65534 (16-bit) or 4200000000-4294967294 (32-bit). Do NOT reuse if you have multiple TGWs that will BGP peer with each other."
  type        = number
  default     = 64512

  validation {
    condition     = (var.tgw_asn >= 64512 && var.tgw_asn <= 65534) || (var.tgw_asn >= 4200000000 && var.tgw_asn <= 4294967294)
    error_message = "Must be a private BGP ASN: 64512-65534 or 4200000000-4294967294."
  }
}

###############################################################################
# NETWORK FIREWALL
###############################################################################

variable "enable_firewall_delete_protection" {
  description = "Protect the Network Firewall from accidental deletion. Set to true in production. When true, you must disable delete protection before running terraform destroy. WARNING: Setting to false in production is a significant risk — a terraform destroy accident would disrupt ALL network traffic through the hub."
  type        = bool
  default     = true
}

variable "firewall_alert_mode" {
  description = "Set to true during initial deployment to use ALERT mode (traffic flows but violations are logged). Set to false for ENFORCE mode (violations are dropped). Start with alert mode, review logs, then flip to enforce. Corresponds to aws:alert_established vs aws:drop_established in the firewall policy."
  type        = bool
  default     = false
}

###############################################################################
# FLOW LOGS
###############################################################################

variable "flow_logs_s3_bucket_arn" {
  description = "ARN of the S3 bucket to receive VPC Flow Logs from all VPCs in this deployment. This should be the centralized log archive bucket (typically in a separate Log Archive account). Example: 'arn:aws:s3:::my-org-log-archive'. The bucket must have a bucket policy allowing the vpc-flow-logs.amazonaws.com service to write to it."
  type        = string
  default     = "arn:aws:s3:::replace-with-your-log-archive-bucket"

  validation {
    condition     = can(regex("^arn:aws:s3:::[a-z0-9.-]+$", var.flow_logs_s3_bucket_arn))
    error_message = "Must be a valid S3 bucket ARN (arn:aws:s3:::bucket-name)."
  }
}

###############################################################################
# TAGGING
###############################################################################

variable "additional_tags" {
  description = "Additional tags to apply to all resources, merged with the default tags set in the provider block. Useful for cost allocation, compliance tags, or team ownership. Example: { CostCenter = 'NET-001', DataClassification = 'Internal' }."
  type        = map(string)
  default     = {}
}

variable "environment" {
  description = "Environment name applied as a tag to all resources. Typically 'network' for the hub/transit layer since this infrastructure spans all environments."
  type        = string
  default     = "network"

  validation {
    condition     = contains(["network", "production", "staging", "development", "sandbox"], var.environment)
    error_message = "Must be one of: network, production, staging, development, sandbox."
  }
}
