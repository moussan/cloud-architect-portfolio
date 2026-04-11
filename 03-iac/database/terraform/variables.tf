###############################################################################
# Database — variables.tf
###############################################################################

variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_id" {
  type = string
  validation {
    condition     = startswith(var.vpc_id, "vpc-")
    error_message = "vpc_id must start with 'vpc-'."
  }
}

variable "data_subnet_ids" {
  type        = list(string)
  description = "Private data-tier subnet IDs. Aurora cluster and proxy ENIs are placed here."
  validation {
    condition     = length(var.data_subnet_ids) >= 2
    error_message = "At least 2 subnets in different AZs required for Aurora Multi-AZ."
  }
}

variable "app_security_group_id" {
  type        = string
  description = "Security group ID of the application tier (ASG). Granted ingress to Aurora on port 3306."
}

variable "cluster_identifier" {
  type        = string
  description = "Short identifier for the Aurora cluster. Full name will be prefixed with environment."
  default     = "main"
}

variable "db_name" {
  type        = string
  description = "Initial database name created in the Aurora cluster."
  default     = "appdb"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]*$", var.db_name))
    error_message = "db_name must start with a letter and contain only letters, numbers, and underscores."
  }
}

variable "db_master_username" {
  type        = string
  description = "Master database username. Do not use 'root', 'admin', or 'master' — use a project-specific name."
  default     = "dbadmin"

  validation {
    condition     = !contains(["root", "admin", "master", "user"], var.db_master_username)
    error_message = "Do not use generic usernames (root, admin, master, user). Use a project-specific username."
  }
}

variable "acu_min" {
  type        = number
  description = "Minimum Aurora Capacity Units for Serverless v2 scaling."
  default     = 0.5

  validation {
    condition     = var.acu_min >= 0.5 && var.acu_min <= 128
    error_message = "acu_min must be between 0.5 and 128."
  }
}

variable "acu_max" {
  type        = number
  description = "Maximum Aurora Capacity Units for Serverless v2 scaling. Set based on expected peak load."
  default     = 64

  validation {
    condition     = var.acu_max >= 1 && var.acu_max <= 128
    error_message = "acu_max must be between 1 and 128."
  }
}

variable "backup_retention_period" {
  type        = number
  description = "Days to retain automated backups. Minimum 7 for production."
  default     = 7

  validation {
    condition     = var.backup_retention_period >= 1 && var.backup_retention_period <= 35
    error_message = "backup_retention_period must be between 1 and 35 days."
  }
}

variable "rotation_lambda_arn" {
  type        = string
  description = "ARN of the Secrets Manager rotation Lambda for RDS MySQL credentials. Deploy from AWS Serverless Application Repository."
}

variable "tags" {
  type    = map(string)
  default = {}
}
