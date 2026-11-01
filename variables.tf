variable "name" {
  description = "Name of the EKS cluster and prefix for related resources."
  type        = string
  default     = "genai-on-eks"
}

variable "region" {
  description = "AWS region. Must offer inf2 instances and have a free Elastic IP for the NAT gateway. Defaults to the upstream workshop region."
  type        = string
  default     = "us-west-2"
}

variable "eks_cluster_version" {
  type    = string
  default = "1.34"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to span (max 4)."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "api_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the PUBLIC EKS API endpoint (IAM auth is still required).
    No default on purpose: run `make tfvars` to write your current public IP, or set it yourself.
    0.0.0.0/0 is rejected.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.api_allowed_cidrs) > 0 && !contains(var.api_allowed_cidrs, "0.0.0.0/0")
    error_message = "api_allowed_cidrs must be non-empty and must not contain 0.0.0.0/0."
  }
}

variable "cluster_admin_principal_arns" {
  description = <<-EOT
    IAM principals (roles or users) that get EKS cluster-admin access in addition to the
    identity running Terraform. Needed so the AWS Console can show nodes/workloads: the
    Console only lists Kubernetes resources for principals that have an EKS access entry.
    Set it to the role you sign in to the Console with, e.g.
    ["arn:aws:iam::<account-id>:role/Admin"]. For SSO roles use the role ARN WITHOUT the
    aws-reserved/sso.amazonaws.com/<region>/ path. Keep the value in terraform.tfvars (git-ignored).
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.cluster_admin_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user)/.+", a)) && !can(regex("aws-reserved/sso\\.amazonaws\\.com", a))])
    error_message = "Each entry must be an IAM role/user ARN; for SSO roles drop the aws-reserved/sso.amazonaws.com/<region>/ path."
  }
}

variable "enable_efs" {
  description = "Create an EFS file system and the 'efs' StorageClass (the upstream workshop config sets up EFS)."
  type        = bool
  default     = true
}

variable "efs_throughput_mode" {
  type    = string
  default = "elastic"
}

# ---------------------------------------------------------------------------
# Workshop components (mirrors upstream workshops/eks-genai-workshop/config.workshop.json)
# ---------------------------------------------------------------------------
variable "vllm_models" {
  description = "Neuron (inf2) vLLM models to deploy. Keys must match files in manifests/vllm/."
  type        = map(bool)
  default = {
    "qwen3-8b-neuron"             = true
    "deepseek-r1-qwen3-8b-neuron" = true
  }
}

variable "bedrock_models" {
  description = "Bedrock models exposed through LiteLLM: name => model id (inference profile id)."
  type        = map(string)
  default = {
    "claude-4.5-sonnet" = "global.anthropic.claude-sonnet-4-5-20250929-v1:0"
  }
}

variable "bedrock_extra_model_ids" {
  description = <<-EOT
    Bedrock model ids the LiteLLM role may invoke in addition to bedrock_models, WITHOUT adding them to
    LiteLLM. Lets the workshop's A1 lab ("add GPT-OSS-20B to LiteLLM", done by hand with helm upgrade)
    work: the model id there is openai.gpt-oss-20b-1:0.
  EOT
  type        = list(string)
  default     = ["openai.gpt-oss-20b-1:0"]
}

variable "admin_email" {
  description = "Admin login e-mail for Langfuse and Open WebUI. Passwords are generated (see `terraform output`)."
  type        = string
  default     = "admin@example.com"
}

variable "litellm_chart_version" {
  type    = string
  default = "1.106.6"
}

variable "litellm_image_tag" {
  description = "Upstream pins this tag in components/ai-gateway/litellm/values.template.yaml."
  type        = string
  default     = "main-v1.81.3-stable"
}

variable "langfuse_chart_version" {
  description = <<-EOT
    Pinned to the last 1.x chart. Upstream's values use the 1.x layout (bitnami
    sub-charts); chart 2.x needs the ClickHouse operator + cert-manager first and has
    a different values schema, so 'latest' (what upstream's unpinned install resolves
    to) does not match those values.
  EOT
  type        = string
  default     = "1.5.41"
}

variable "openwebui_chart_version" {
  description = "Same version upstream pins in components/gui-app/openwebui/index.mjs."
  type        = string
  default     = "12.8.1"
}

variable "openwebui_storage_size" {
  type    = string
  default = "20Gi"
}
