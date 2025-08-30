variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_profile" {
  description = "AWS CLI profile name"
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "sideproj-eks"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}
