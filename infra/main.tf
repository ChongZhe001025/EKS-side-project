locals {
  azs = ["${var.region}a", "${var.region}b", "${var.region}c"]
}

# 1) VPC（可用 terraform-aws-modules/vpc/aws）
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = local.azs
  private_subnets = ["10.0.1.0/24","10.0.2.0/24","10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24","10.0.102.0/24","10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

# 2) EKS（使用 terraform-aws-modules/eks/aws）
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  enable_irsa = true  # 開 IRSA，後續安裝控制器方便

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2_x86_64"
      instance_types = var.node_instance_types
      min_size       = var.min_size
      max_size       = var.max_size
      desired_size   = var.desired_size

      # 建議開啟 Spot 混合可再加上 capacity_type = "SPOT"
    }
  }

  tags = {
    Project = "sideproj"
  }
}

# 可選：輸出 kubeconfig 所需資訊（也可直接用 aws cli 更新）
