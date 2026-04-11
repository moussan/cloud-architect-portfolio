###############################################################################
# Outputs — Hub-and-Spoke Network Architecture
# Author: Moussa El Najmi, Senior AWS Solutions Architect
#
# These outputs expose the key resource identifiers needed by:
#   - Application module deployments (which VPC/subnet to deploy into)
#   - DNS configuration (VPC IDs for PHZ association)
#   - Security tooling (flow log bucket locations, firewall ARN for WAF chaining)
#   - Monitoring dashboards (TGW ID for CloudWatch metrics)
#   - Cross-account automation (TGW ID to share via RAM)
#
# Usage in dependent modules:
#   data "terraform_remote_state" "networking" {
#     backend = "s3"
#     config = {
#       bucket = "your-tfstate-bucket"
#       key    = "network/hub-spoke/terraform.tfstate"
#       region = "us-east-1"
#     }
#   }
#   subnet_id = data.terraform_remote_state.networking.outputs.prod_private_subnet_ids[0]
###############################################################################

###############################################################################
# TRANSIT GATEWAY
###############################################################################

output "transit_gateway_id" {
  description = "ID of the Transit Gateway. Share this via AWS RAM to attach VPCs from other accounts. Reference in spoke-account Terraform to create TGW attachments. Format: tgw-xxxxxxxxxxxxxxxxx."
  value       = aws_ec2_transit_gateway.main.id
}

output "transit_gateway_arn" {
  description = "ARN of the Transit Gateway. Required for RAM resource share configuration and IAM policies that grant TGW attachment rights."
  value       = aws_ec2_transit_gateway.main.arn
}

output "tgw_route_table_prod_id" {
  description = "ID of the TGW route table for the Production domain. New prod-account TGW attachments should be associated with this route table. Contains blackhole routes for dev/staging CIDRs."
  value       = aws_ec2_transit_gateway_route_table.prod.id
}

output "tgw_route_table_nonprod_id" {
  description = "ID of the TGW route table for the Non-Production domain. Dev and Staging VPC attachments associate with this table. Contains blackhole route for Prod CIDR."
  value       = aws_ec2_transit_gateway_route_table.nonprod.id
}

output "tgw_route_table_inspection_id" {
  description = "ID of the TGW route table for the Inspection domain. The Hub VPC attachment is associated with this table. Contains propagated routes from all spoke VPCs to enable return-path routing."
  value       = aws_ec2_transit_gateway_route_table.inspection.id
}

output "tgw_route_table_shared_services_id" {
  description = "ID of the TGW route table for Shared Services. Use for Shared Services VPC attachments that need visibility into all other domains."
  value       = aws_ec2_transit_gateway_route_table.shared_services.id
}

output "tgw_attachment_hub_id" {
  description = "ID of the TGW attachment for the Hub (Inspection) VPC. Reference when creating TGW static routes that need to send traffic to the hub (e.g., 0.0.0.0/0 default routes in spoke route tables)."
  value       = aws_ec2_transit_gateway_vpc_attachment.hub.id
}

output "tgw_attachment_prod_id" {
  description = "ID of the TGW attachment for the Prod VPC."
  value       = aws_ec2_transit_gateway_vpc_attachment.prod.id
}

output "tgw_attachment_dev_id" {
  description = "ID of the TGW attachment for the Dev VPC."
  value       = aws_ec2_transit_gateway_vpc_attachment.dev.id
}

###############################################################################
# VPC IDs
###############################################################################

output "hub_vpc_id" {
  description = "ID of the Hub (Inspection) VPC. Use for: VPC endpoint creation, Security Group references, Route 53 PHZ association."
  value       = aws_vpc.hub.id
}

output "prod_vpc_id" {
  description = "ID of the Production spoke VPC. Use for workload deployments, RDS subnet group creation, EKS cluster VPC configuration."
  value       = aws_vpc.prod.id
}

output "dev_vpc_id" {
  description = "ID of the Development spoke VPC."
  value       = aws_vpc.dev.id
}

###############################################################################
# SUBNET IDS — HUB VPC
###############################################################################

output "hub_public_subnet_ids" {
  description = "List of public subnet IDs in the Hub VPC (one per AZ). Use for: NAT Gateway placement, external ALB deployment, internet-facing resources."
  value       = aws_subnet.hub_public[*].id
}

output "hub_firewall_subnet_ids" {
  description = "List of firewall subnet IDs in the Hub VPC. Network Firewall endpoints reside here. Do not deploy application workloads to these subnets."
  value       = aws_subnet.hub_firewall[*].id
}

output "hub_tgw_subnet_ids" {
  description = "List of TGW attachment subnet IDs in the Hub VPC (one /28 per AZ). The TGW ENIs for the hub attachment are placed in these subnets."
  value       = aws_subnet.hub_tgw[*].id
}

###############################################################################
# SUBNET IDS — PROD VPC
###############################################################################

output "prod_public_subnet_ids" {
  description = "List of public subnet IDs in the Prod VPC (one per AZ). Note: these subnets have NO IGW route — 'public' here refers to the intended tier. Use for public-facing ALBs that will be fronted by a TGW-connected hub ALB, or reserve for future use."
  value       = aws_subnet.prod_public[*].id
}

output "prod_private_subnet_ids" {
  description = "List of private subnet IDs in the Prod VPC (one per AZ). Use for: EC2 instances, EKS node groups, ECS tasks, Lambda VPC deployments. Internet egress via TGW → Hub NAT GW."
  value       = aws_subnet.prod_private[*].id
}

output "prod_data_subnet_ids" {
  description = "List of data subnet IDs in the Prod VPC (one per AZ). Use for: RDS instances, ElastiCache clusters, MSK brokers, OpenSearch domains. No internet route — fully isolated from internet egress."
  value       = aws_subnet.prod_data[*].id
}

output "prod_tgw_subnet_ids" {
  description = "List of TGW attachment subnet IDs in the Prod VPC. The TGW ENIs for the prod attachment are placed here."
  value       = aws_subnet.prod_tgw[*].id
}

###############################################################################
# SUBNET IDS — DEV VPC
###############################################################################

output "dev_public_subnet_ids" {
  description = "List of public subnet IDs in the Dev VPC (one per AZ)."
  value       = aws_subnet.dev_public[*].id
}

output "dev_private_subnet_ids" {
  description = "List of private subnet IDs in the Dev VPC (one per AZ). Use for development workload deployments."
  value       = aws_subnet.dev_private[*].id
}

output "dev_data_subnet_ids" {
  description = "List of data subnet IDs in the Dev VPC (one per AZ). Use for development databases and caches."
  value       = aws_subnet.dev_data[*].id
}

output "dev_tgw_subnet_ids" {
  description = "List of TGW attachment subnet IDs in the Dev VPC."
  value       = aws_subnet.dev_tgw[*].id
}

###############################################################################
# NETWORK FIREWALL
###############################################################################

output "network_firewall_arn" {
  description = "ARN of the AWS Network Firewall. Reference in IAM policies for firewall management, and in monitoring configurations for CloudWatch metrics and NFW logging."
  value       = aws_networkfirewall_firewall.main.arn
}

output "network_firewall_id" {
  description = "ID of the AWS Network Firewall."
  value       = aws_networkfirewall_firewall.main.id
}

output "network_firewall_policy_arn" {
  description = "ARN of the Network Firewall policy. Reference when creating additional rule group associations programmatically."
  value       = aws_networkfirewall_firewall_policy.main.arn
}

output "network_firewall_endpoint_ids" {
  description = "Map of AZ name → Network Firewall endpoint ID (VPC endpoint IDs). These endpoint IDs are used as route table targets. Indexed as: { 'us-east-1a' = 'vpce-xxx', 'us-east-1b' = 'vpce-yyy', 'us-east-1c' = 'vpce-zzz' }."
  value       = local.nfw_endpoints
}

###############################################################################
# NAT GATEWAYS
###############################################################################

output "nat_gateway_ids" {
  description = "List of NAT Gateway IDs (one per AZ). Used for monitoring NAT Gateway metrics in CloudWatch."
  value       = aws_nat_gateway.hub[*].id
}

output "nat_gateway_public_ips" {
  description = "List of Elastic IP addresses assigned to NAT Gateways (one per AZ). These are the fixed outbound IPs for all spoke VPC internet traffic. Share these with third parties for allowlisting."
  value       = aws_eip.hub_nat[*].public_ip
}

###############################################################################
# INTERNET GATEWAY
###############################################################################

output "hub_internet_gateway_id" {
  description = "ID of the Internet Gateway attached to the Hub VPC. This is the ONLY IGW in the architecture — all internet traffic flows through here."
  value       = aws_internet_gateway.hub.id
}

###############################################################################
# ROUTE TABLES
###############################################################################

output "prod_private_route_table_id" {
  description = "ID of the route table attached to Prod private subnets. Reference when adding additional routes (e.g., VPC endpoints, specific on-prem prefixes)."
  value       = aws_route_table.prod_private.id
}

output "prod_data_route_table_id" {
  description = "ID of the route table attached to Prod data subnets."
  value       = aws_route_table.prod_data.id
}

output "dev_private_route_table_id" {
  description = "ID of the route table attached to Dev private subnets."
  value       = aws_route_table.dev_private.id
}

output "hub_public_route_table_ids" {
  description = "List of route table IDs for Hub public subnets (one per AZ)."
  value       = aws_route_table.hub_public[*].id
}

output "hub_firewall_route_table_ids" {
  description = "List of route table IDs for Hub firewall subnets (one per AZ). These route tables have NFW as the return path for east-west traffic."
  value       = aws_route_table.hub_firewall[*].id
}

output "hub_tgw_route_table_ids" {
  description = "List of route table IDs for Hub TGW attachment subnets (one per AZ). These tables force all traffic through the NFW endpoint."
  value       = aws_route_table.hub_tgw[*].id
}

###############################################################################
# FLOW LOGS
###############################################################################

output "flow_log_hub_id" {
  description = "ID of the VPC Flow Log resource for the Hub VPC."
  value       = aws_flow_log.hub.id
}

output "flow_log_prod_id" {
  description = "ID of the VPC Flow Log resource for the Prod VPC."
  value       = aws_flow_log.prod.id
}

output "flow_log_dev_id" {
  description = "ID of the VPC Flow Log resource for the Dev VPC."
  value       = aws_flow_log.dev.id
}

###############################################################################
# CONVENIENCE / COMPOSITE
###############################################################################

output "all_vpc_ids" {
  description = "Map of VPC name → VPC ID for all VPCs managed by this module. Useful for iterating in dependent modules."
  value = {
    hub  = aws_vpc.hub.id
    prod = aws_vpc.prod.id
    dev  = aws_vpc.dev.id
  }
}

output "all_private_subnet_ids" {
  description = "Flat list of all private subnet IDs across all VPCs. Useful for mass security group / NACL operations."
  value = concat(
    aws_subnet.prod_private[*].id,
    aws_subnet.dev_private[*].id,
  )
}

output "availability_zones" {
  description = "List of the 3 Availability Zones used by this deployment. AZ index alignment: hub_public[0] is in availability_zones[0], etc."
  value       = local.azs
}
