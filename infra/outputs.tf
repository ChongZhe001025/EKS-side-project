output "cluster_name"    { value = module.eks.cluster_name }
output "cluster_endpoint"{ value = module.eks.cluster_endpoint }
output "argocd_server_lb" {
  description = "Argo CD Server LoadBalancer (kubectl get svc -n argocd argocd-server)"
  value       = "kubectl get svc -n argocd argocd-server -o wide"
}
output "alb_controller_sa" {
  description = "AWS Load Balancer Controller Service Account (kubectl get sa -n kube-system aws-load-balancer-controller -o wide)"
  value       = "kubectl get sa -n kube-system aws-load-balancer-controller -o wide"
}