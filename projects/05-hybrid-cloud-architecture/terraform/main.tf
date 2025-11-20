terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Transit Gateway
resource "aws_ec2_transit_gateway" "this" {
  description = "${var.project_name}-tgw"

  tags = {
    Name = "${var.project_name}-tgw"
  }
}

# Example VPC attachments (prod + shared-services)
resource "aws_ec2_transit_gateway_vpc_attachment" "prod" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = var.prod_vpc_id
  subnet_ids         = var.prod_tgw_subnet_ids

  tags = {
    Name = "${var.project_name}-prod-attachment"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "shared" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = var.shared_vpc_id
  subnet_ids         = var.shared_tgw_subnet_ids

  tags = {
    Name = "${var.project_name}-shared-attachment"
  }
}

# Example DX Gateway (placeholder, requires DX connection config)
resource "aws_dx_gateway" "this" {
  name            = "${var.project_name}-dxgw"
  amazon_side_asn = 64512
}

resource "aws_dx_gateway_association" "tgw_assoc" {
  dx_gateway_id         = aws_dx_gateway.this.id
  associated_gateway_id = aws_ec2_transit_gateway.this.id

  allowed_prefixes = var.allowed_prefixes
}

# Site-to-site VPN to on-prem (simplified)
resource "aws_vpn_gateway" "this" {
  vpc_id = var.shared_vpc_id

  tags = {
    Name = "${var.project_name}-vpn-gw"
  }
}
