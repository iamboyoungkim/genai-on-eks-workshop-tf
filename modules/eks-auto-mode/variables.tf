variable "name" { type = string }
variable "region" { type = string }
variable "eks_cluster_version" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "api_allowed_cidrs" { type = list(string) }

variable "cluster_admin_principal_arns" {
  description = "Extra principals granted AmazonEKSClusterAdminPolicy (e.g. the Console sign-in role)."
  type        = list(string)
  default     = []
}

variable "enable_efs" {
  description = "Install the EFS CSI driver and the 'efs' StorageClass. Must be known at plan time."
  type        = bool
  default     = false
}

variable "efs_file_system_id" {
  description = "EFS file system id (only used when enable_efs = true; may be unknown until apply)."
  type        = string
  default     = ""
}
