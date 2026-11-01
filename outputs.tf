output "cluster_name" {
  value = module.eks_auto_mode.cluster_name
}

output "region" {
  value = var.region
}

output "kubeconfig_command" {
  description = "Writes a project-local kubeconfig (does not touch ~/.kube/config). `make kubeconfig` does this."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks_auto_mode.cluster_name} --kubeconfig .kubeconfig"
}

output "access" {
  description = "Nothing is exposed publicly. Use `make port-forward` (binds 127.0.0.1 only)."
  value = {
    open_webui = "http://127.0.0.1:8000"
    litellm    = "http://127.0.0.1:4000  (UI: /ui)"
    langfuse   = "http://127.0.0.1:3000"
  }
}

output "credentials" {
  description = "Generated credentials. Show with: terraform output -json credentials"
  sensitive   = true
  value = {
    admin_email         = var.admin_email
    openwebui_password  = random_password.openwebui_admin.result
    langfuse_password   = random_password.langfuse_admin.result
    litellm_ui_user     = "admin"
    litellm_ui_password = random_password.litellm_ui.result
    litellm_master_key  = local.litellm_master_key
    langfuse_public_key = local.langfuse_public_key
    langfuse_secret_key = local.langfuse_secret_key
  }
}

# The workshop's A2 deploy script reads these two with `terraform output -raw ...`
# (upstream defines them in components/o11y/langfuse). scripts/workshop-shim/terraform
# forwards those calls to this stack.
output "langfuse_bucket_name" {
  description = "S3 bucket used by Langfuse (Loan Buddy stores uploaded documents here)."
  value       = aws_s3_bucket.langfuse.id
}

output "langfuse_s3_role_arn" {
  description = "IAM role (Pod Identity) that grants Langfuse access to that bucket."
  value       = aws_iam_role.langfuse.arn
}
