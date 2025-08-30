data "aws_iam_policy_document" "argocd_optional" {
  statement {
    sid     = "OptionalSecretsManagerRead"
    effect  = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParameterHistory"
    ]
    resources = ["*"]
  }
  # 需要 S3 時再開：
  # statement {
  #   sid     = "OptionalS3Read"
  #   effect  = "Allow"
  #   actions = ["s3:GetObject","s3:ListBucket"]
  #   resources = ["arn:aws:s3:::your-helm-bucket", "arn:aws:s3:::your-helm-bucket/*"]
  # }
}

resource "aws_iam_policy" "argocd_optional" {
  name        = "${var.cluster_name}-argocd-optional"
  description = "Optional minimal AWS read for Argo CD (Secrets Manager/SSM)"
  policy      = data.aws_iam_policy_document.argocd_optional.json
  tags        = local.tags
}

module "argocd_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  create_role      = true
  role_name        = "${var.cluster_name}-argocd"
  role_policy_arns = {
    argocd = aws_iam_policy.argocd_optional.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["argocd:argocd-server"]
      # 需要時再加："argocd:argocd-repo-server"
    }
  }

  tags = local.tags
}
