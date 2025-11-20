variable "region" {
  type        = string
  default     = "us-east-1"
}

variable "security_account_email" {
  type        = string
  description = "Email for the security account"
}

variable "prod_account_email" {
  type        = string
  description = "Email for the prod account"
}

variable "allowed_regions" {
  type        = list(string)
  default     = ["ca-central-1", "us-east-1"]
}
