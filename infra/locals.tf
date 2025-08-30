locals {
  project_tag = "sideproj-eks"
  tags = {
    Project = local.project_tag
    Owner   = "czhuang"
  }
  
  github_subjects = [
    "repo:ChongZhe001025/EKS-side-project:ref:refs/heads/main",
    # 需要可再加其他分支或 tags / pull_request
    # "repo:ChongZhe001025/EKS-side-project:ref:refs/heads/release",
    # "repo:ChongZhe001025/EKS-side-project:ref:refs/tags/v*",
    # "repo:ChongZhe001025/EKS-side-project:pull_request",
  ]
}
