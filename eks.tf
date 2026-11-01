provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.name
      ManagedBy = "terraform"
      Purpose   = "genai-on-eks-workshop"
    }
  }
}

module "eks_auto_mode" {
  source = "./modules/eks-auto-mode"

  name                = var.name
  region              = var.region
  eks_cluster_version = var.eks_cluster_version
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.private_subnets
  api_allowed_cidrs   = var.api_allowed_cidrs

  cluster_admin_principal_arns = var.cluster_admin_principal_arns
  enable_efs                   = var.enable_efs
  efs_file_system_id           = var.enable_efs ? aws_efs_file_system.this[0].id : ""

  depends_on = [aws_efs_mount_target.this]
}

# Providers are configured here (not inside the module) from the cluster that the
# module creates, so one `terraform apply` can build the cluster and install on it.
locals {
  eks_exec_args = ["eks", "--region", var.region, "get-token", "--cluster-name", module.eks_auto_mode.cluster_name]
}

provider "kubernetes" {
  host                   = module.eks_auto_mode.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_auto_mode.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.eks_exec_args
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks_auto_mode.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_auto_mode.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.eks_exec_args
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks_auto_mode.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_auto_mode.cluster_certificate_authority_data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.eks_exec_args
  }
}
