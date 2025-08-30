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

variable "enable_amp_remote_write" {
  description = "是否啟用 Prometheus remote_write 到 AMP"
  type        = bool
  default     = false
}

variable "amp_workspace_id" {
  description = "Amazon Managed Prometheus Workspace 的 ID"
  type        = string
}