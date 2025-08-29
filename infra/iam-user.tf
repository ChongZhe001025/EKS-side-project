resource "aws_iam_user" "czhuang_cli" {
  name = "czhuang-cli"
  tags = { Project = "sideproj-eks" }
}

# 先給 PowerUser；之後換成自訂最小策略
resource "aws_iam_user_policy_attachment" "czhuang_poweruser" {
  user       = aws_iam_user.czhuang_cli.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# 建議：用 Console 建立/輪替 Access Key，並強制 MFA。
# 如確需 IaC 建立，可解開下列資源（並保護 state）
# resource "aws_iam_access_key" "czhuang_cli_key" {
#   user = aws_iam_user.czhuang_cli.name
# }
