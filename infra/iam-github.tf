locals {
  project_tag = "sideproj-eks"
  # 授權的 GitHub OIDC sub（精準到 repo + branch）
  # 格式請用：repo:OWNER/REPO:ref:refs/heads/<branch>
  github_subjects = [
    "repo:ChongZhe001025/EKS-side-project:ref:refs/heads/main",
  ]
}

# 1) GitHub OIDC Provider（token.actions.githubusercontent.com）
module "iam_oidc_provider" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-oidc-provider"
  version = "~> 5.48"

  url = "https://token.actions.githubusercontent.com"
  tags = { Project = local.project_tag }
}

# 2) MVP 寬權限（供 Terraform/CI 使用；之後請最小化）
data "aws_iam_policy_document" "gha_tf_infra" {
  statement {
    sid     = "EKSAndInfra"
    effect  = "Allow"
    actions = [
      "eks:*",
      "ec2:*",
      "iam:*",
      "autoscaling:*",
      "sts:GetCallerIdentity",
      "logs:*",
      "cloudwatch:*",
      "elasticloadbalancing:*",
      "acm:ListCertificates",
      "acm:DescribeCertificate",
      "route53:*"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "gha_tf_infra" {
  name        = "gha-terraform-infra"
  description = "GitHub Actions role for Terraform to manage ${local.project_tag}"
  policy      = data.aws_iam_policy_document.gha_tf_infra.json
  tags        = { Project = local.project_tag }
}

# 3) GitHub OIDC 可被 Assume 的 Role（正確子模組：iam-role）
module "gha_role_terraform" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 5.48"

  name = "gha-terraform-${local.project_tag}"

  # 啟用 GitHub OIDC 信任，並指定允許的 subjects
  enable_github_oidc         = true
  # 精準 subjects（完全比對）
  oidc_fully_qualified_subjects = local.github_subjects
  # 若要用萬用字元可改用：oidc_wildcard_subjects = ["OWNER/REPO:*"]

  # 附上你上面建立的 Policy（也可放 AWS 托管策略 ARN）
  policies = {
    infra = aws_iam_policy.gha_tf_infra.arn
  }

  tags = { Project = local.project_tag }
}

output "gha_terraform_role_arn" {
  value = module.gha_role_terraform.iam_role_arn
}
