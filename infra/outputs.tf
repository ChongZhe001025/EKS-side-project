output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}

output "gha_role_arn" {
  value = aws_iam_role.gha_deployer.arn
}

output "alb_controller_role_arn" {
  value = aws_iam_role.alb_controller_irsa.arn
}
