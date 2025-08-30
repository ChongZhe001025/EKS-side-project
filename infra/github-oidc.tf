# GitHub OIDC Provider
module "iam_oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-oidc-provider"
  version = "~> 5.60"

  url  = "https://token.actions.githubusercontent.com"
  tags = { Project = local.project_tag }
}

# GitHub Actions 專用 IAM Role（給 Terraform/CI AssumeRole）
module "gha_role_terraform" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 5.60"

  name = "gha-terraform"

  assume_role_principals = {
    # 直接用上面 provider 輸出的 arn
    federated = [module.iam_oidc_provider.arn]
  }

  # 讓特定 repo/branch 能 AssumeRole
  # 例：repo:OWNER/REPO:ref:refs/heads/main
  oidc_subjects = local.github_subjects

  policy_documents = [
    data.aws_iam_policy_document.gha_tf_infra.json
  ]

  tags = { Project = local.project_tag }
}
