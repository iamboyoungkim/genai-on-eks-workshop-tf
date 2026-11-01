# Adapted from upstream terraform/modules/eks-auto-mode/eks.tf (see UPSTREAM.md).
# Changes: public API endpoint is restricted to api_allowed_cidrs; no ECR pull-through
# cache policy; no local-exec kubeconfig side effect (use `make kubeconfig`).

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.3.1"

  name               = var.name
  kubernetes_version = var.eks_cluster_version

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.api_allowed_cidrs

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  enable_cluster_creator_admin_permissions = true

  compute_config = {
    enabled    = true
    node_pools = ["general-purpose"]
  }
}
