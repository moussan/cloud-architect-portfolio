###############################################################################
# Variables — Production VPC Module
# Author: Moussa El Najmi, Senior AWS Solutions Architect
###############################################################################

variable "vpc_name" {
  description = "Name prefix for this VPC and all its resources. Example: 'prod', 'dev', 'shared-services'. Used in: resource names, tags, and log path prefixes."
  type        = string

  validation {
    condition     = length(var.vpc_name) <= 20 && can(regex("^[a-z0-9-]+$", var.vpc_name))
    error_message = "Must be lowercase alphanumeric with hyphens, max 20 characters."
  }
}

variable "vpc_cidr" {
  description = "Primary CIDR block for the VPC. Must be a /16 for the subnet calculations in this module to work correctly. Must not overlap with other VPCs or on-premises networks. Use RFC 1918: 10.0.0.0/8, 172.16.0.0/12, or 192.168.0.0/16."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) == 16
    error_message = "Must be a valid /16 CIDR block (e.g., 10.1.0.0/16)."
  }
}

variable "environment" {
  description = "Environment name for tagging. Determines resource naming context."
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging", "development", "sandbox", "shared", "network"], var.environment)
    error_message = "Must be one of: production, staging, development, sandbox, shared, network."
  }
}

variable "create_igw" {
  description = "Create an Internet Gateway for this VPC. Set false for spoke VPCs in a hub-and-spoke architecture that use centralized egress via TGW. Set true for standalone VPCs or the hub VPC."
  type        = bool
  default     = true
}

variable "enable_nat_gateway" {
  description = "Create NAT Gateways (one per AZ) for outbound internet access from private subnets. Set false if using centralized NAT via TGW → Hub VPC. Setting false saves ~$97/month (3 NAT GWs) but requires a TGW with a hub that has NAT GWs."
  type        = bool
  default     = true
}

variable "transit_gateway_id" {
  description = "ID of an existing Transit Gateway to attach to this VPC. When provided, adds TGW as the next hop for private subnet routes. Leave empty for standalone VPCs. Example: 'tgw-0123456789abcdef0'."
  type        = string
  default     = ""
}

variable "create_interface_endpoints" {
  description = "Create Interface VPC Endpoints for SSM, CloudWatch Logs, and STS. Enables Session Manager (no bastion needed) and keeps AWS API traffic private. Cost: ~$21.60/month per endpoint for 3 AZs. Strongly recommended for production."
  type        = bool
  default     = true
}

variable "create_ecr_endpoints" {
  description = "Create ECR API and DKR Interface Endpoints. Required for EKS and ECS to pull images without NAT Gateway. Cost: ~$21.60/month per endpoint. Enable when running containers."
  type        = bool
  default     = false
}

variable "flow_logs_s3_bucket_arn" {
  description = "ARN of the S3 bucket for VPC Flow Logs. Leave empty to skip flow log creation (not recommended for production). Use a centralized log archive bucket. Format: 'arn:aws:s3:::bucket-name'."
  type        = string
  default     = ""
}

variable "additional_tags" {
  description = "Additional tags to merge with default resource tags. Use for cost allocation, compliance, and team ownership. Example: { CostCenter = 'PROD-001', Compliance = 'PCI-DSS' }."
  type        = map(string)
  default     = {}
}
