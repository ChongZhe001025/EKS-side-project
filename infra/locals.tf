locals {
  project_tag = "sideproj-eks"
  tags = {
    Project = local.project_tag
    Owner   = "czhuang"
  }
}
