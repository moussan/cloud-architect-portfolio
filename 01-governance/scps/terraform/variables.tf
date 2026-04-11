###############################################################################
# SCPs — variables.tf
###############################################################################

variable "region" {
  description = "AWS region for provider configuration."
  type        = string
  default     = "ca-central-1"
}

variable "allowed_regions" {
  description = "List of AWS regions permitted by the DenyNonAllowedRegions SCP."
  type        = list(string)
  default     = ["ca-central-1", "us-east-1"]
}

variable "terraform_state_bucket" {
  description = "S3 bucket name for Terraform remote state (landing zone outputs)."
  type        = string
}

variable "terraform_state_region" {
  description = "Region of the Terraform state S3 bucket."
  type        = string
  default     = "ca-central-1"
}
