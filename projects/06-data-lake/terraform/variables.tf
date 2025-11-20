variable "project_name" {
  type    = string
  default = "data-lake"
}

variable "region" {
  type    = string
  default = "ca-central-1"
}

variable "glue_role_arn" {
  type        = string
  description = "IAM role ARN for Glue crawler"
}
