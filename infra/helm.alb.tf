resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.10.1"

  values = [yamlencode({
    clusterName = module.eks.cluster_name
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.alb_irsa.iam_role_arn
      }
    }
    region = var.aws_region
    vpcId  = module.vpc.vpc_id
  })]

  depends_on = [module.eks, module.alb_irsa]
}
