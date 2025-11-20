variable "project_name" {
  type    = string
  default = "hybrid-cloud"
}

variable "region" {
  type    = string
  default = "ca-central-1"
}

variable "prod_vpc_id" {
  type = string
}

variable "shared_vpc_id" {
  type = string
}

variable "prod_tgw_subnet_ids" {
  type = list(string)
}

variable "shared_tgw_subnet_ids" {
  type = list(string)
}

variable "allowed_prefixes" {
  type        = list(string)
  description = "On-prem prefixes allowed via DXGW"
  default     = ["10.0.0.0/8"]
}
