output "vpc_id"             { value = module.vpc.vpc_id }
output "eks_cluster_name"   { value = module.eks.cluster_name }

output "cluster_name"       { value = module.eks.cluster_name }
output "cluster_endpoint"   { value = module.eks.cluster_endpoint }

output "alb_controller_role_arn" {
  value       = module.alb_irsa.iam_role_arn
  description = "ALB Controller IRSA Role ARN"
}

output "prometheus_amp_role_arn" {
  value       = try(module.prometheus_amp_irsa.iam_role_arn, null)
  description = "Prometheus → AMP IRSA Role ARN（未啟用則為 null）"
}

output "argocd_role_arn" {
  value       = try(module.argocd_irsa.iam_role_arn, null)
  description = "Argo CD IRSA Role ARN（未啟用則為 null）"
}

output "argocd_server_lb" {
  description = "kubectl 指令：查詢 Argo CD Server LB"
  value       = "kubectl get svc -n argocd argocd-server -o wide"
}

output "alb_controller_sa" {
  description = "kubectl 指令：查詢 ALB Controller SA"
  value       = "kubectl get sa -n kube-system aws-load-balancer-controller -o wide"
}
