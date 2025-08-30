module "prometheus_amp_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  create_role      = true
  role_name        = "${var.cluster_name}-prometheus-amp"
  role_policy_arns = ["arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess"]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["monitoring:kube-prometheus-stack-prometheus"]
    }
  }

  tags = local.tags
}
