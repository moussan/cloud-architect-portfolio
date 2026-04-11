###############################################################################
# VPC Design Module — outputs.tf
###############################################################################

output "vpc_id" {
  description = "The ID of the VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "The CIDR block of the VPC."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "List of public subnet IDs (one per AZ)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of private (application) subnet IDs (one per AZ)."
  value       = aws_subnet.private[*].id
}

output "data_subnet_ids" {
  description = "List of data (isolated) subnet IDs (one per AZ)."
  value       = aws_subnet.data[*].id
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway (null if create_igw = false)."
  value       = length(aws_internet_gateway.main) > 0 ? aws_internet_gateway.main[0].id : null
}

output "nat_gateway_ids" {
  description = "List of NAT Gateway IDs (empty list if enable_nat_gateway = false)."
  value       = aws_nat_gateway.main[*].id
}

output "nat_gateway_public_ips" {
  description = "Public Elastic IPs associated with the NAT Gateways."
  value       = aws_eip.nat[*].public_ip
}

output "s3_endpoint_id" {
  description = "ID of the S3 Gateway Endpoint."
  value       = aws_vpc_endpoint.s3.id
}

output "dynamodb_endpoint_id" {
  description = "ID of the DynamoDB Gateway Endpoint."
  value       = aws_vpc_endpoint.dynamodb.id
}

output "public_route_table_ids" {
  description = "IDs of the public subnet route tables."
  value       = aws_route_table.public[*].id
}

output "private_route_table_ids" {
  description = "IDs of the private subnet route tables."
  value       = aws_route_table.private[*].id
}

output "data_route_table_ids" {
  description = "IDs of the data subnet route tables."
  value       = aws_route_table.data[*].id
}
