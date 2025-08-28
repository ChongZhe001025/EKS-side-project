data "aws_caller_identity" "me" {}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # NOTE: Update if GitHub rotates certificates
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "gha_deployer" {
  name = "${var.name}-gha-deployer"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      },
      Action = "sts:AssumeRoleWithWebIdentity",
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/*"
          ]
        },
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "gha_deploy_policy" {
  name        = "${var.name}-gha-deploy-policy"
  description = "Permissions for GitHub Actions to deploy to EKS"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { "Effect": "Allow", "Action": ["eks:DescribeCluster"], "Resource": "*" },
      { "Effect": "Allow", "Action": ["iam:PassRole","iam:CreateServiceLinkedRole"], "Resource": "*" }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "gha_attach" {
  role       = aws_iam_role.gha_deployer.name
  policy_arn = aws_iam_policy.gha_deploy_policy.arn
}
