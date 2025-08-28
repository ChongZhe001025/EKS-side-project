variable "region" {
  description = "AWS region to deploy to"
  type        = string
  default     = "ap-southeast-2"
}

variable "name" {
  description = "Base name for your EKS cluster and related resources"
  type        = string
  default     = "sideproj-eks"
}

variable "github_owner" {
  description = "GitHub organization or username that hosts the repo"
  type        = string
  default     = "ChongZHe001025"
}

variable "github_repo" {
  description = "GitHub repository name that will deploy to EKS"
  type        = string
  default     = "EKS-side-project"
}
