data "tls_certificate" "gha" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.gha.certificates[0].sha1_fingerprint]

  tags = {
    Project = local.project_tag
  }
}
data "aws_iam_policy_document" "gha_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # 支援多個 subjects
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_subjects
    }
  }
}

resource "aws_iam_role" "gha_terraform" {
  name               = "gha-terraform"
  assume_role_policy = data.aws_iam_policy_document.gha_assume_role.json

  tags = {
    Project = local.project_tag
  }
}
resource "aws_iam_role_policy_attachment" "gha_admin" {
  role       = aws_iam_role.gha_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}

output "gha_terraform_role_arn" {
  value = aws_iam_role.gha_terraform.arn
}
