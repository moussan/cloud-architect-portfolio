###############################################################################
# Database — outputs.tf
###############################################################################

output "cluster_endpoint" {
  description = "Aurora cluster writer endpoint. Use only for schema migrations and admin tasks. Application traffic should use the proxy endpoint."
  value       = aws_rds_cluster.main.endpoint
}

output "cluster_reader_endpoint" {
  description = "Aurora cluster reader endpoint. Use for read-only queries when not going through the proxy."
  value       = aws_rds_cluster.main.reader_endpoint
}

output "proxy_endpoint" {
  description = "RDS Proxy endpoint. This is the connection endpoint applications should use."
  value       = aws_db_proxy.main.endpoint
}

output "cluster_identifier" {
  description = "Aurora cluster identifier. Used in AWS CLI commands and console navigation."
  value       = aws_rds_cluster.main.cluster_identifier
}

output "database_name" {
  description = "Database name within the Aurora cluster."
  value       = aws_rds_cluster.main.database_name
}

output "secret_arn" {
  description = "Secrets Manager secret ARN for database credentials. Grant applications access to this ARN."
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "aurora_security_group_id" {
  description = "Aurora security group ID. Other modules that need database access must reference this SG."
  value       = aws_security_group.aurora.id
}

output "kms_key_arn" {
  description = "KMS CMK ARN for Aurora storage encryption. Reference in backup and cross-account snapshot policies."
  value       = aws_kms_key.aurora.arn
}
