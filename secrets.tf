# All credentials are generated here. Nothing secret is written in this repository
# (upstream ships fixed defaults such as "password123"; those are replaced).
# Values live in Terraform state: keep the state private, and move it to an encrypted
# remote backend if you share this stack. Read them with `make creds`.

resource "random_password" "litellm_master_key" {
  length  = 32
  special = false
}

resource "random_password" "litellm_ui" {
  length  = 20
  special = false
}

resource "random_password" "langfuse_admin" {
  length  = 20
  special = false
}

resource "random_password" "openwebui_admin" {
  length  = 20
  special = false
}

# Langfuse project API keys (also handed to LiteLLM for tracing)
resource "random_password" "langfuse_public_key" {
  length  = 24
  special = false
}

resource "random_password" "langfuse_secret_key" {
  length  = 32
  special = false
}

# Langfuse internals
resource "random_password" "langfuse_salt" {
  length  = 32
  special = false
}

resource "random_password" "langfuse_nextauth" {
  length  = 32
  special = false
}

resource "random_id" "langfuse_encryption_key" {
  byte_length = 32 # 64 hex chars, as the chart requires
}

resource "random_password" "langfuse_postgres" {
  length  = 24
  special = false
}

resource "random_password" "langfuse_clickhouse" {
  length  = 24
  special = false
}

resource "random_password" "langfuse_redis" {
  length  = 24
  special = false
}

locals {
  litellm_master_key  = "sk-${random_password.litellm_master_key.result}"
  langfuse_public_key = "pk-lf-${random_password.langfuse_public_key.result}"
  langfuse_secret_key = "sk-lf-${random_password.langfuse_secret_key.result}"
}
