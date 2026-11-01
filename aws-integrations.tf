# AWS resources the platform charts need, wired through EKS Pod Identity
# (no static AWS keys in the cluster).

locals {
  pod_identity_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  # global.anthropic.claude-... -> anthropic.claude-... (foundation model behind the profile)
  bedrock_all_model_ids  = distinct(concat(values(var.bedrock_models), var.bedrock_extra_model_ids))
  bedrock_foundation_ids = distinct([for id in local.bedrock_all_model_ids : replace(id, "/^(global|us|eu|apac|jp|au)\\./", "")])
}

# ------------------------------- Langfuse -> S3 -----------------------------
resource "aws_s3_bucket" "langfuse" {
  bucket_prefix = "${var.name}-langfuse-"
  # Workshop stack: allow `terraform destroy` to remove a non-empty bucket.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "langfuse" {
  bucket                  = aws_s3_bucket.langfuse.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "langfuse" {
  bucket = aws_s3_bucket.langfuse.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_iam_role" "langfuse" {
  name               = "${var.name}-${var.region}-langfuse-s3"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy" "langfuse" {
  role = aws_iam_role.langfuse.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.langfuse.arn, "${aws_s3_bucket.langfuse.arn}/*"]
    }]
  })
}

resource "aws_eks_pod_identity_association" "langfuse" {
  cluster_name    = module.eks_auto_mode.cluster_name
  namespace       = "langfuse"
  service_account = "langfuse"
  role_arn        = aws_iam_role.langfuse.arn
}

# ------------------------------ LiteLLM -> Bedrock --------------------------
resource "aws_iam_role" "litellm" {
  name               = "${var.name}-${var.region}-litellm-bedrock"
  assume_role_policy = local.pod_identity_trust
}

# Least privilege: only the configured inference profiles / foundation models
# (upstream grants bedrock:* invoke on "*").
resource "aws_iam_role_policy" "litellm_bedrock" {
  role = aws_iam_role.litellm.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
      Resource = concat(
        [for id in local.bedrock_all_model_ids : "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/${id}"],
        [for id in local.bedrock_foundation_ids : "arn:aws:bedrock:*::foundation-model/${id}"],
      )
    }]
  })
}

resource "aws_eks_pod_identity_association" "litellm" {
  cluster_name    = module.eks_auto_mode.cluster_name
  namespace       = "litellm"
  service_account = "litellm"
  role_arn        = aws_iam_role.litellm.arn
}
