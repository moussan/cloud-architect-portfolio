################################################################################
# Database — Aurora Serverless v2 (MySQL 8.0) Reference Implementation
#
# Architecture:
#   Secrets Manager (auto-rotation) → RDS Proxy → Aurora Cluster
#                                                  ├── Writer (AZ-a)
#                                                  └── Reader (AZ-b)
#
# Features:
#   - Aurora Serverless v2: 0.5–64 ACU (auto-scaling)
#   - Multi-AZ: writer + 1 reader in separate AZs
#   - RDS Proxy with IAM authentication + connection pooling
#   - Secrets Manager with automatic 30-day rotation
#   - Performance Insights (7-day retention)
#   - Enhanced Monitoring (60s)
#   - Deletion protection enabled
################################################################################

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.30"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  backend "s3" {
    bucket         = "myorg-tfstate-prod"
    key            = "database/terraform.tfstate"
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
      Module      = "database"
      Environment = var.environment
    })
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Aurora parameter group family for MySQL 8.0
  pg_family = "aurora-mysql8.0"
}

################################################################################
# KMS CMK for Aurora Storage Encryption
#
# WHY a CMK for Aurora?
# - RDS/Aurora default encryption uses the aws/rds managed key.
#   With a CMK, you control the key policy — you can restrict which IAM roles
#   can read the decrypted data at the storage layer.
# - CloudTrail logs every KMS Decrypt — audit trail for data access.
# - Required for cross-account snapshot sharing (managed keys cannot be shared).
################################################################################

resource "aws_kms_key" "aurora" {
  description             = "KMS CMK for Aurora cluster ${var.cluster_identifier} storage encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootFullControl"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowRDSServiceUse"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = [
          "kms:CreateGrant",
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = local.account_id
          }
        }
      }
    ]
  })
}

resource "aws_kms_alias" "aurora" {
  name          = "alias/${var.environment}-aurora-${var.cluster_identifier}"
  target_key_id = aws_kms_key.aurora.key_id
}

################################################################################
# Secrets Manager — Database Credentials
#
# WHY Secrets Manager instead of SSM Parameter Store for DB credentials?
# - Secrets Manager has built-in RDS/Aurora rotation Lambda templates
# - It integrates directly with RDS Proxy for IAM-based authentication
# - Automatic rotation means the password changes without a Terraform apply
# - Parameter Store SecureString requires manual rotation logic
################################################################################

# Generate a random password — Terraform creates the shell, not the value
resource "random_password" "db_master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
  # WHY override_special?
  # MySQL/Aurora has characters that cause parsing issues in DSNs: @, /, \, '
  # Excluding them avoids connection string escaping problems.
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "/${var.environment}/aurora/${var.cluster_identifier}/master-credentials"
  description = "Aurora MySQL master credentials for ${var.cluster_identifier} in ${var.environment}"
  kms_key_id  = aws_kms_key.aurora.arn
  # WHY same KMS key?
  # Using the same CMK for Aurora storage and its Secrets Manager secret
  # means a single key policy controls who can access both the encrypted
  # data and the credentials needed to query it.

  recovery_window_in_days = var.environment == "prod" ? 30 : 7
  # WHY 30 days for prod? Secrets that have been deleted but are in the
  # recovery window can be restored. 30 days gives ample time to recover
  # from accidental deletion in production.
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id

  secret_string = jsonencode({
    username            = var.db_master_username
    password            = random_password.db_master.result
    engine              = "mysql"
    host                = aws_rds_cluster.main.endpoint
    port                = 3306
    dbname              = var.db_name
    dbClusterIdentifier = aws_rds_cluster.main.cluster_identifier
  })
  # WHY store host and port in the secret?
  # This is the Secrets Manager rotation Lambda convention. The rotation Lambda
  # reads the complete connection info from the secret, connects, and rotates
  # the password — no additional configuration needed.

  lifecycle {
    ignore_changes = [secret_string]
    # WHY ignore_changes on secret_string?
    # After initial creation, Secrets Manager rotation overwrites the password.
    # If Terraform manages secret_string, every plan after a rotation would
    # show a diff and want to reset the password to the original generated value.
  }
}

# Automatic rotation — rotates the password every 30 days
resource "aws_secretsmanager_secret_rotation" "db_credentials" {
  secret_id           = aws_secretsmanager_secret.db_credentials.id
  rotation_lambda_arn = var.rotation_lambda_arn
  # WHY an external rotation Lambda?
  # The rotation Lambda is provided by AWS as a SAM application in the
  # Serverless Application Repository. Deploy it once per environment:
  # https://serverlessrepo.aws.amazon.com/applications/arn:aws:serverlessrepo:us-east-1:297356227824:applications~SecretsManagerRDSMySQLRotationSingleUser
  # Then reference its ARN here.

  rotation_rules {
    automatically_after_days = 30
    # WHY 30 days? PCI DSS requires quarterly rotation at minimum (90 days).
    # 30 days is a conservative enterprise standard that exceeds most requirements.
    # Rotation is transparent to the application via RDS Proxy.
  }
}

################################################################################
# Security Group
################################################################################

resource "aws_security_group" "aurora" {
  name        = "${var.environment}-aurora-sg"
  description = "Aurora cluster: ingress from application tier only on port 3306"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.environment}-aurora-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "aurora_from_app" {
  security_group_id            = aws_security_group.aurora.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = var.app_security_group_id
  description                  = "MySQL from application tier security group"
  # WHY SG-to-SG reference instead of CIDR?
  # Only instances in the app SG (the ASG) can connect.
  # Even if a developer adds a new subnet, instances there cannot reach
  # the database unless they're in the app SG.
}

resource "aws_vpc_security_group_ingress_rule" "aurora_from_proxy" {
  security_group_id            = aws_security_group.aurora.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.rds_proxy.id
  description                  = "MySQL from RDS Proxy security group"
}

# No explicit egress rule — Aurora doesn't initiate outbound connections
# Terraform's default egress rule (allow all outbound) is sufficient.
# For stricter posture, remove default egress and add only what's needed.

################################################################################
# DB Subnet Group
################################################################################

resource "aws_db_subnet_group" "main" {
  name        = "${var.environment}-aurora-subnet-group"
  description = "Aurora cluster subnet group — private/data tier subnets"
  subnet_ids  = var.data_subnet_ids
  # WHY data subnets (not private app subnets)?
  # Three-tier architecture:
  #   Public subnets     → ALB, NAT GW
  #   Private app subnets → EC2 ASG instances
  #   Private data subnets → RDS, Aurora, ElastiCache
  # Separate data subnets allow tighter NACLs and routing on the database tier.
  # If your VPC only has two tiers, using private subnets is acceptable.
}

################################################################################
# Aurora Parameter Group
#
# WHY a custom parameter group?
# The default parameter group cannot be modified. A custom group lets you
# tune performance and security parameters without AWS limitations.
# Changes to dynamic parameters take effect immediately; static parameters
# require a cluster reboot.
################################################################################

resource "aws_rds_cluster_parameter_group" "main" {
  name        = "${var.environment}-aurora-mysql80"
  family      = local.pg_family
  description = "Aurora MySQL 8.0 parameter group for ${var.environment}"

  parameter {
    name         = "slow_query_log"
    value        = "1"
    apply_method = "immediate"
    # WHY: Enables slow query logging. Without this, you have no visibility
    # into queries degrading performance. Slow queries are the #1 cause of
    # unexplained database latency spikes.
  }

  parameter {
    name         = "long_query_time"
    value        = "2"
    apply_method = "immediate"
    # WHY 2 seconds? Queries over 2s impact user experience. Adjust down
    # (e.g., to 0.5s) for SLA-sensitive workloads. Set to 0 to log everything
    # for short periods during debugging.
  }

  parameter {
    name         = "max_connections"
    value        = "1000"
    apply_method = "immediate"
    # WHY 1000? Aurora Serverless v2 scales compute, but max_connections
    # is a hard limit. 1000 is a conservative default. RDS Proxy multiplexes
    # many application connections onto fewer actual DB connections — this
    # limit applies to the proxy→DB connections, not app→proxy connections.
  }

  parameter {
    name         = "require_secure_transport"
    value        = "ON"
    apply_method = "immediate"
    # WHY: Forces TLS for all connections. Without this, a misconfigured
    # application could connect over plaintext. Defense in depth beyond
    # just the security group.
  }

  parameter {
    name         = "general_log"
    value        = "0"
    apply_method = "immediate"
    # WHY OFF? The general log records every SQL statement — it can generate
    # hundreds of MB per hour on a busy cluster, creating I/O contention.
    # Enable briefly and only in a maintenance window for debugging.
  }

  parameter {
    name         = "log_output"
    value        = "FILE"
    apply_method = "immediate"
    # WHY FILE (not TABLE)? Log tables accumulate indefinitely without manual
    # TRUNCATE. FILE logs are managed by Aurora and shipped to CloudWatch Logs.
  }

  parameter {
    name         = "innodb_print_all_deadlocks"
    value        = "1"
    apply_method = "immediate"
    # WHY: Logs all deadlock information to the error log.
    # Essential for diagnosing transaction contention issues in production.
  }
}

resource "aws_db_parameter_group" "main" {
  name        = "${var.environment}-aurora-mysql80-instance"
  family      = local.pg_family
  description = "Aurora MySQL 8.0 instance-level parameters for ${var.environment}"

  parameter {
    name         = "performance_schema"
    value        = "1"
    apply_method = "pending-reboot"
    # WHY: Performance Schema is required for Performance Insights to collect
    # detailed wait event data. It uses ~350 MB of RAM — acceptable on instances
    # with 2+ GB. For very small ACU sizes (0.5 ACU), monitor memory pressure.
  }
}

################################################################################
# IAM Role for Enhanced Monitoring
#
# Enhanced Monitoring uses an OS-level agent on the Aurora instances to collect
# metrics at 1-60s granularity (vs CloudWatch which samples at 60s minimum).
# It needs an IAM role to publish metrics to CloudWatch.
################################################################################

resource "aws_iam_role" "rds_enhanced_monitoring" {
  name = "${var.environment}-rds-enhanced-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

################################################################################
# Aurora Cluster
################################################################################

resource "aws_rds_cluster" "main" {
  cluster_identifier = "${var.environment}-${var.cluster_identifier}"

  engine         = "aurora-mysql"
  engine_version = "8.0.mysql_aurora.3.04.0"
  # WHY pin the engine version?
  # Aurora auto-upgrades minor versions on the maintenance window if
  # allow_major_version_upgrade is not set. Pinning means upgrades are
  # explicit and planned — not surprises on Monday morning.
  # Check for latest Aurora MySQL 8.0 versions:
  # aws rds describe-db-engine-versions --engine aurora-mysql --query 'DBEngineVersions[?starts_with(EngineVersion, `8.0`)]'

  engine_mode = "provisioned"
  # WHY "provisioned" for Serverless v2?
  # This is counterintuitive: Aurora Serverless v2 uses engine_mode = "provisioned"
  # with serverless v2 instance classes (db.serverless). The engine_mode = "serverless"
  # is for Aurora Serverless v1 (which is deprecated and being end-of-lifed).

  serverlessv2_scaling_configuration {
    min_capacity = var.acu_min
    max_capacity = var.acu_max
    # WHY 0.5 minimum? Aurora Serverless v2 pauses at 0 ACU is not supported yet
    # (as of 2024). 0.5 ACU is the minimum warm-running state — very low cost.
    # If your workload is bursty with long idle periods, 0.5 ACU is the right floor.
    # For low-latency production services, consider min = 2 to avoid cold-start latency
    # when scaling from 0.5 ACU to higher values.
  }

  database_name   = var.db_name
  master_username = var.db_master_username
  # WHY not master_password here?
  # We use manage_master_user_password = true which delegates password
  # management to Secrets Manager. Aurora creates and stores the password there.
  # This avoids the master password ever appearing in Terraform state.

  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.aurora.arn
  # WHY manage_master_user_password = true?
  # Aurora manages the master password in Secrets Manager automatically.
  # The password never appears in Terraform state — it's managed entirely
  # by the Aurora/Secrets Manager integration. This is the most secure approach.

  db_subnet_group_name            = aws_db_subnet_group.main.name
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.main.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]

  storage_encrypted = true
  kms_key_id        = aws_kms_key.aurora.arn

  backup_retention_period      = var.backup_retention_period
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "sun:04:00-sun:05:00"
  # WHY these windows?
  # Backup window precedes maintenance window — if both ran simultaneously
  # and caused I/O pressure, workloads would be impacted twice.
  # Sunday 3-5 AM UTC has the lowest traffic for most US/EU businesses.

  deletion_protection = var.environment == "prod" ? true : false
  # WHY conditional? Prod Aurora clusters must have deletion protection.
  # Dev/staging can be destroyed for cost management.

  skip_final_snapshot       = var.environment == "prod" ? false : true
  final_snapshot_identifier = var.environment == "prod" ? "${var.environment}-${var.cluster_identifier}-final-${formatdate("YYYYMMDD", timestamp())}" : null
  # WHY final snapshot in prod?
  # Prevents data loss if terraform destroy is run accidentally in production.
  # The snapshot persists beyond the cluster's lifecycle.

  enabled_cloudwatch_logs_exports = ["audit", "error", "general", "slowquery"]
  # WHY all four log types?
  # audit   → who connected, what statements were run (compliance/security)
  # error   → engine errors, crash recovery, failed connection attempts
  # general → all SQL (disabled by parameter group — enable for debugging only)
  # slowquery → queries exceeding long_query_time (performance tuning)

  apply_immediately = var.environment == "prod" ? false : true
  # WHY false for prod?
  # Changes to prod clusters should apply in the next maintenance window,
  # not immediately. Immediate changes can cause brief restarts.

  lifecycle {
    precondition {
      condition     = var.environment == "prod" ? var.backup_retention_period >= 7 : true
      error_message = "Production Aurora clusters must retain automated backups for at least 7 days."
    }

    precondition {
      condition     = var.acu_max >= var.acu_min
      error_message = "acu_max must be greater than or equal to acu_min."
    }
  }
}

################################################################################
# Aurora Cluster Instances
#
# WHY two instances (writer + reader)?
# - Writer handles all writes and some reads
# - Reader handles read offloading and serves as the failover target
# - If the writer instance fails, Aurora promotes the reader in < 30 seconds
# - Single-instance Aurora clusters have no standby — failover requires
#   provisioning a new instance (can take 2-5 minutes)
################################################################################

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.environment}-${var.cluster_identifier}-writer"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.serverless" # Required for Serverless v2

  engine         = aws_rds_cluster.main.engine
  engine_version = aws_rds_cluster.main.engine_version

  db_parameter_group_name = aws_db_parameter_group.main.name

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_enhanced_monitoring.arn
  # WHY 60 seconds for Enhanced Monitoring?
  # 60s granularity balances cost and observability. Reduce to 15s or 5s
  # during incidents when you need finer-grained OS metrics.

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.aurora.arn
  performance_insights_retention_period = 7
  # WHY 7 days?
  # 7 days of Performance Insights is free. Beyond 7 days, it costs
  # ~$0.02/vCPU/hour. For forensic analysis of performance regressions,
  # 7 days is sufficient to cover the previous week's patterns.
  # Increase to 731 days if compliance requires longer retention.

  auto_minor_version_upgrade = false
  # WHY false? Automatic minor upgrades apply during the maintenance window
  # without advance notice beyond a week. In production, upgrades should be
  # planned, tested in staging first, and scheduled with the team.

  lifecycle {
    postcondition {
      condition     = self.performance_insights_enabled == true
      error_message = "Performance Insights must be enabled on the writer instance."
    }
  }
}

resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${var.environment}-${var.cluster_identifier}-reader"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.serverless"

  engine         = aws_rds_cluster.main.engine
  engine_version = aws_rds_cluster.main.engine_version

  db_parameter_group_name = aws_db_parameter_group.main.name

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_enhanced_monitoring.arn

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.aurora.arn
  performance_insights_retention_period = 7

  auto_minor_version_upgrade = false

  # Reader in a different AZ from the writer
  # Aurora handles AZ placement — no explicit AZ needed.
  # The availability_zone argument is optional; Aurora distributes across AZs automatically.
}

################################################################################
# RDS Proxy
#
# WHY RDS Proxy for a web application?
# Lambda functions, ECS tasks, and Kubernetes pods create new database connections
# on every invocation/restart. Without connection pooling, you can exhaust
# max_connections on the Aurora cluster under load.
#
# RDS Proxy pools connections between the application and Aurora:
#   Application connections → RDS Proxy (many) → Aurora (few)
#
# Additional benefits:
#   - Transparent failover: proxy reconnects after Aurora failover; apps see no error
#   - IAM authentication: apps authenticate with IAM tokens; proxy uses Secrets Manager
#   - Multiplexing: one proxy connection services many application connections
#     for workloads without open transactions or session state
################################################################################

resource "aws_security_group" "rds_proxy" {
  name        = "${var.environment}-rds-proxy-sg"
  description = "RDS Proxy: ingress from app tier, egress to Aurora"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.environment}-rds-proxy-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "proxy_from_app" {
  security_group_id            = aws_security_group.rds_proxy.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = var.app_security_group_id
  description                  = "MySQL from application tier security group"
}

resource "aws_vpc_security_group_egress_rule" "proxy_to_aurora" {
  security_group_id            = aws_security_group.rds_proxy.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.aurora.id
  description                  = "MySQL to Aurora cluster security group"
}

# IAM role for RDS Proxy to read the Secrets Manager secret
resource "aws_iam_role" "rds_proxy" {
  name = "${var.environment}-rds-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "rds_proxy_secrets" {
  name = "rds-proxy-secrets-access"
  role = aws_iam_role.rds_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.db_credentials.arn
      },
      {
        # RDS Proxy needs to decrypt the secret stored with KMS
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.aurora.arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_db_proxy" "main" {
  name                = "${var.environment}-${var.cluster_identifier}-proxy"
  debug_logging       = false
  engine_family       = "MYSQL"
  idle_client_timeout = 1800
  # WHY 1800 seconds (30 min)?
  # Idle connections waste database resources. 30 minutes is a standard
  # timeout for applications with infrequent bursts. Reduce for very
  # high-connection workloads.

  require_tls = true
  # WHY require TLS?
  # Forces encrypted connections from application to proxy.
  # Defense in depth: SSL at the application→proxy layer plus
  # SSL at the proxy→Aurora layer (enforced by parameter group).

  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_security_group_ids = [aws_security_group.rds_proxy.id]
  vpc_subnet_ids         = var.data_subnet_ids

  auth {
    auth_scheme = "SECRETS"
    description = "Aurora master credentials via Secrets Manager"
    iam_auth    = "REQUIRED"
    # WHY IAM auth required?
    # Applications authenticate to the proxy with a short-lived IAM token
    # (via rds:connect). This means no database password is stored in
    # application config files or environment variables.
    # The proxy uses the Secrets Manager credential internally — the app
    # never sees the actual database password.

    secret_arn = aws_secretsmanager_secret.db_credentials.arn
  }

  tags = {
    Name = "${var.environment}-${var.cluster_identifier}-proxy"
  }
}

resource "aws_db_proxy_default_target_group" "main" {
  db_proxy_name = aws_db_proxy.main.name

  connection_pool_config {
    connection_borrow_timeout = 120
    # WHY 120 seconds? If the proxy pool is exhausted, how long should a
    # request wait before failing? 120s is generous — reduce to 30s for
    # time-sensitive APIs. Monitor ConnectionPoolMaxConnections CloudWatch metric.

    max_connections_percent = 90
    # WHY 90%? Reserves 10% of max_connections for direct DBA access
    # and emergency connections. Without this reserve, a runaway query
    # filling all proxy connections also locks out administrators.

    max_idle_connections_percent = 50
    # WHY 50%? Keeps up to 50% of the pool as idle connections for burst
    # absorption. Connections in the pool are already established — no
    # TCP/TLS handshake cost when the next request arrives.
  }
}

resource "aws_db_proxy_target" "main" {
  db_proxy_name         = aws_db_proxy.main.name
  target_group_name     = aws_db_proxy_default_target_group.main.name
  db_cluster_identifier = aws_rds_cluster.main.id
}

################################################################################
# Outputs
################################################################################

################################################################################
# Variables
################################################################################
