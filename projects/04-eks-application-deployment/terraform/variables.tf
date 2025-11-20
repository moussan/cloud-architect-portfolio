variable "region" {
  type    = string
  default = "ca-central-1"
}

variable "cluster_name" {
  type        = string
  description = "Existing EKS cluster name"
}

variable "namespace" {
  type    = string
  default = "sample-app"
}

variable "image" {
  type        = string
  default     = "nginx:stable"
  description = "Container image for the sample web app"
}
