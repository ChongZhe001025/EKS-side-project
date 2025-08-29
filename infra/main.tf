locals {
  tags = {
    Project = "sideproj-eks"
    Owner   = "czhuang"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.7"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = ["${var.region}a", "${var.region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name                   = var.cluster_name
  cluster_version                = "1.30"
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_irsa = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 3
      desired_size   = 2
    }
  }

  # 可選：讓建立叢集的人自帶 admin（便於本機初始操作）
  enable_cluster_creator_admin_permissions = true

  # ★ 新增：EKS Access Entries（取代 aws-auth）
  access_entries = {
    github_actions = {
      principal_arn = module.gha_role_terraform.iam_role_arn

      policy_associations = [
        {
          # 叢集管理員權限（MVP 可用，之後可降權）
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      ]
    }
  }

  tags = local.tags
}


# ALB Controller 用 IRSA
module "alb_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name                              = "${var.cluster_name}-alb-controller"
  attach_load_balancer_controller_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.tags
}

# 安裝 AWS Load Balancer Controller（Helm）
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.10.1"  # 對應 EKS 1.30 的穩定版

  values = [yamlencode({
    clusterName = module.eks.cluster_name
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.alb_irsa.iam_role_arn
      }
    }
    region = var.region
    vpcId  = module.vpc.vpc_id
  })]

  depends_on = [module.eks]
}

# （可選）用 TF 先裝 Argo CD，之後讓它自管
resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = "argocd"
  create_namespace = true
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "6.7.17"

  values = [yamlencode({
    server = {
      service = {
        type = "LoadBalancer"
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
        }
      }
    }
  })]

  depends_on = [module.eks, helm_release.alb_controller]
}
