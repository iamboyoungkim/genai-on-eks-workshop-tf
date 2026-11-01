data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

# Same VPC layout as upstream terraform/vpc.tf (private + public subnets, single NAT).
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = var.name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 64)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.name
  }
}

# ---------------------------------------------------------------------------
# EFS (upstream terraform/efs.tf)
# ---------------------------------------------------------------------------
resource "aws_security_group" "efs" {
  count = var.enable_efs ? 1 : 0

  name        = "${var.name}-efs-sg"
  description = "NFS from private subnets only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "NFS from private subnets"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = module.vpc.private_subnets_cidr_blocks
  }

  tags = {
    Name                     = "${var.name}-efs-sg"
    "karpenter.sh/discovery" = var.name
  }
}

resource "aws_efs_file_system" "this" {
  count = var.enable_efs ? 1 : 0

  creation_token  = "${var.name}-efs"
  encrypted       = true
  throughput_mode = var.efs_throughput_mode

  lifecycle_policy {
    transition_to_ia = "AFTER_7_DAYS"
  }
  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }

  tags = {
    Name = "${var.name}-efs"
  }
}

resource "aws_efs_mount_target" "this" {
  count = var.enable_efs ? length(module.vpc.private_subnets) : 0

  file_system_id  = aws_efs_file_system.this[0].id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs[0].id]
}
