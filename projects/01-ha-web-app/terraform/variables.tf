variable "project_name" {
  type        = string
  description = "Prefix for resource names"
  default     = "ha-web-app"
}

variable "region" {
  type        = string
  description = "AWS region"
  default     = "ca-central-1"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block"
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "azs" {
  type        = list(string)
  description = "Availability zones"
  default     = ["ca-central-1a", "ca-central-1b"]
}

variable "ami_id" {
  type        = string
  description = "AMI ID for web instances"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "asg_min_size" {
  type    = number
  default = 2
}

variable "asg_max_size" {
  type    = number
  default = 4
}

variable "asg_desired_capacity" {
  type    = number
  default = 2
}

variable "user_data" {
  type        = string
  description = "User data script to configure web server"
  default     = <<-EOT
              #!/bin/bash
              yum update -y
              yum install -y httpd
              systemctl enable httpd
              systemctl start httpd
              echo "Hello from HA Web App" > /var/www/html/index.html
              EOT
}
