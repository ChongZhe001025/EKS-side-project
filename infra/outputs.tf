output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "node_group_role_arn" {
  value = module.eks.eks_managed_node_groups["default"].iam_role_arn
}
output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${var.cluster_name}"
}
