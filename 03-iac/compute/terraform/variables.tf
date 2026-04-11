################################################################################
# Compute Module — Variables
#
# Every variable that could be misconfigured has a validation block.
# The goal: catch logical errors before Terraform makes a single API call.
################################################################################

variable "environment" {
  type        = string
  description = "Deployment environment. Controls deletion protection, instance sizing guardrails, and monitoring configuration."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "region" {
  type        = string
  description = "AWS region for all compute resources."
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.region))
    error_message = "region must be a valid AWS region (e.g., us-east-1, eu-west-2)."
  }
}

################################################################################
# Networking
################################################################################

variable "vpc_id" {
  type        = string
  description = "VPC ID where compute resources will be deployed."

  validation {
    condition     = startswith(var.vpc_id, "vpc-")
    error_message = "vpc_id must be a valid VPC ID starting with 'vpc-'."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block. Used to scope ASG egress security group rules to VPC endpoints only."

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block (e.g., 10.0.0.0/16)."
  }
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnet IDs for the Application Load Balancer. Must span at least 2 AZs."

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "At least 2 public subnets in different AZs are required for ALB high availability."
  }

  validation {
    condition     = alltrue([for s in var.public_subnet_ids : startswith(s, "subnet-")])
    error_message = "All public_subnet_ids must be valid subnet IDs starting with 'subnet-'."
  }
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for ASG instances. Must span at least 2 AZs."

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least 2 private subnets in different AZs are required for ASG high availability."
  }

  validation {
    condition     = alltrue([for s in var.private_subnet_ids : startswith(s, "subnet-")])
    error_message = "All private_subnet_ids must be valid subnet IDs starting with 'subnet-'."
  }
}

################################################################################
# EC2 / Launch Template
################################################################################

variable "ami_id" {
  type        = string
  description = "AMI ID for the Launch Template. Should be a Golden AMI produced by EC2 Image Builder."

  validation {
    condition     = startswith(var.ami_id, "ami-")
    error_message = "ami_id must be a valid AMI ID starting with 'ami-'."
  }
}

variable "instance_type" {
  type        = string
  description = "Default instance type for the Launch Template. The ASG mixed-instances policy will also use spot_instance_types."
  default     = "m6i.large"

  # Cross-variable constraint (environment, min/max checks) enforced via precondition in main.tf

  validation {
    # t3.micro and t3.nano are too small for a load-bearing web tier
    condition     = !contains(["t3.micro", "t3.nano", "t2.micro", "t2.nano"], var.instance_type)
    error_message = "Micro and nano instance types are insufficient for a production web tier. Minimum recommended: t3.small for dev, m6i.large for prod."
  }
}

variable "spot_instance_types" {
  type        = list(string)
  description = "Instance types for the Spot fleet in the ASG mixed-instances policy. Diversify across families to reduce interruptions."
  default     = ["m6i.large", "m6a.large", "m5.large", "c6i.large", "c5.large"]

  validation {
    condition     = length(var.spot_instance_types) >= 3
    error_message = "Provide at least 3 Spot instance types to ensure adequate capacity diversification and reduce interruption probability."
  }
}

variable "root_volume_size" {
  type        = number
  description = "Root EBS volume size in GB."
  default     = 30

  validation {
    condition     = var.root_volume_size >= 20 && var.root_volume_size <= 500
    error_message = "root_volume_size must be between 20 and 500 GB."
  }
}

################################################################################
# Auto Scaling Group
################################################################################

variable "asg_min_size" {
  type        = number
  description = "Minimum number of instances in the ASG."
  default     = 2

  validation {
    condition     = var.asg_min_size >= 1
    error_message = "asg_min_size must be at least 1."
  }

  # Cross-variable constraint (environment, min/max checks) enforced via precondition in main.tf
}

variable "asg_max_size" {
  type        = number
  description = "Maximum number of instances. Sets an upper bound on cost. Should be at least 2x the expected peak demand."
  default     = 10

  # Cross-variable constraint (environment, min/max checks) enforced via precondition in main.tf

  validation {
    condition     = var.asg_max_size <= 100
    error_message = "asg_max_size > 100 requires explicit review. If you need more than 100 instances, ensure Service Quotas are requested and billing alarms are in place."
  }
}

variable "asg_desired_capacity" {
  type        = number
  description = "Initial desired capacity. After the first apply, the ASG manages this via target tracking. Terraform will ignore subsequent changes (see lifecycle.ignore_changes in main.tf)."
  default     = 2

  # Cross-variable constraint (environment, min/max checks) enforced via precondition in main.tf
}

variable "on_demand_base_capacity" {
  type        = number
  description = "Number of On-Demand instances to maintain as a baseline. Remaining instances above this count use Spot."
  default     = 1

  # Cross-variable constraint (environment, min/max checks) enforced via precondition in main.tf
}

variable "health_check_grace_period" {
  type        = number
  description = "Seconds to wait after launching an instance before starting ELB health checks. Set this to the time your application takes to fully start."
  default     = 300

  validation {
    condition     = var.health_check_grace_period >= 60 && var.health_check_grace_period <= 900
    error_message = "health_check_grace_period must be between 60 and 900 seconds."
  }
}

################################################################################
# Scaling Policy
################################################################################

variable "cpu_target_value" {
  type        = number
  description = "Target CPU utilization percentage for the target tracking scaling policy."
  default     = 60.0

  validation {
    condition     = var.cpu_target_value >= 40.0 && var.cpu_target_value <= 85.0
    error_message = "cpu_target_value should be between 40 and 85. Below 40 over-provisions instances. Above 85 leaves no headroom for traffic spikes while new instances are launching."
  }
}

variable "alb_requests_per_target" {
  type        = number
  description = "Target ALB request count per instance for the request-count scaling policy."
  default     = 1000

  validation {
    condition     = var.alb_requests_per_target >= 100
    error_message = "alb_requests_per_target must be at least 100. Values below this will cause excessive scaling activity."
  }
}

################################################################################
# Application
################################################################################

variable "app_port" {
  type        = number
  description = "TCP port the application listens on. ALB forwards to this port on instances."
  default     = 8080

  validation {
    condition     = var.app_port >= 1024 && var.app_port <= 65535
    error_message = "app_port must be between 1024 and 65535. Ports below 1024 require root privileges."
  }
}

variable "health_check_path" {
  type        = string
  description = "HTTP path for ALB target group health checks. Must return HTTP 200."
  default     = "/health"

  validation {
    condition     = startswith(var.health_check_path, "/")
    error_message = "health_check_path must start with '/'."
  }
}

variable "app_config_bucket" {
  type        = string
  description = "S3 bucket name containing application configuration files. Instances have read access to the environment-scoped prefix."
}

################################################################################
# DNS / TLS
################################################################################

variable "domain_name" {
  type        = string
  description = "Domain name for the ACM certificate lookup (e.g., api.example.com). The certificate must be in ISSUED status in ACM."

  validation {
    condition     = can(regex("^[a-z0-9*][a-z0-9.*-]*[a-z0-9]$", var.domain_name))
    error_message = "domain_name must be a valid domain name (e.g., api.example.com or *.example.com)."
  }
}

variable "alb_access_log_bucket" {
  type        = string
  description = "S3 bucket name for ALB access logs. Must have the correct bucket policy to accept ALB logs (elb-account-id prefix)."
}

################################################################################
# Tags
################################################################################

variable "tags" {
  type        = map(string)
  description = "Additional tags applied to all resources. Merged with module-default tags (Environment, ManagedBy, Module)."
  default     = {}

  validation {
    condition     = !contains(keys(var.tags), "ManagedBy")
    error_message = "Do not set 'ManagedBy' in var.tags — it is set automatically to 'terraform' by this module."
  }
}
