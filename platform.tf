# Workshop platform layer: Langfuse -> LiteLLM -> Open WebUI.
# Values are derived from upstream components/*/values.template.yaml with these changes:
#   * no Ingress / ALB: every Service stays ClusterIP (reach them via `make port-forward`)
#   * credentials generated in secrets.tf instead of fixed defaults
#   * chart versions pinned
# Images under public.ecr.aws/agentic-ai-platforms-on-k8s/* are the upstream workshop's
# public mirror of the bitnami sub-chart images.

locals {
  ecr_mirror = "agentic-ai-platforms-on-k8s"

  langfuse_url_internal = "http://langfuse-web.langfuse:3000"

  litellm_model_list = concat(
    [for name, _ in local.vllm_enabled : {
      model_name = "vllm/${name}"
      litellm_params = {
        model    = "openai/${name}"
        api_key  = "fake-key" # vLLM has no auth; LiteLLM just needs a non-empty value
        api_base = "http://${name}.vllm:8000/v1"
      }
    }],
    [for name, id in var.bedrock_models : {
      model_name = "bedrock/${name}"
      litellm_params = {
        model           = "bedrock/${id}"
        aws_region_name = var.region
      }
    }],
    # A3 model-routing lab: one virtual model, two weighted deployments (80% Claude / 20% Qwen).
    # Built with for-expressions on purpose: a `cond ? [...] : []` expression unifies the element types and
    # Terraform then turns `weight` into a string ("8"), which makes LiteLLM's simple-shuffle fail
    # ("unsupported operand type(s) for +: 'int' and 'str'").
    [for _ in(var.enable_ab_routing ? [1] : []) : {
      model_name = "loan-processing"
      litellm_params = {
        model           = "bedrock/${var.bedrock_models["claude-4.5-sonnet"]}"
        aws_region_name = var.region
        weight          = 8
      }
    }],
    [for _ in(var.enable_ab_routing ? [1] : []) : {
      model_name = "loan-processing"
      litellm_params = {
        model    = "openai/qwen3-8b-neuron"
        api_key  = "fake-key"
        api_base = "http://qwen3-8b-neuron.vllm:8000/v1"
        weight   = 2
      }
    }],
    # A3 model-routing step 3 (complexity-based routing): the app picks the group, the gateway pins the backend.
    [for _ in(var.enable_ab_routing ? [1] : []) : {
      model_name = "loan-processing-simple"
      litellm_params = {
        model    = "openai/qwen3-8b-neuron"
        api_key  = "fake-key"
        api_base = "http://qwen3-8b-neuron.vllm:8000/v1"
      }
    }],
    [for _ in(var.enable_ab_routing ? [1] : []) : {
      model_name = "loan-processing-complex"
      litellm_params = {
        model           = "bedrock/${var.bedrock_models["claude-4.5-sonnet"]}"
        aws_region_name = var.region
      }
    }],
  )
}

# ------------------------------- Langfuse ----------------------------------
resource "helm_release" "langfuse" {
  name             = "langfuse"
  namespace        = "langfuse"
  create_namespace = true
  repository       = "https://langfuse.github.io/langfuse-k8s"
  chart            = "langfuse"
  version          = var.langfuse_chart_version
  timeout          = 900

  values = [yamlencode({
    global = { security = { allowInsecureImages = true } }

    langfuse = {
      salt          = { value = random_password.langfuse_salt.result }
      nextauth      = { secret = { value = random_password.langfuse_nextauth.result } }
      encryptionKey = { value = random_id.langfuse_encryption_key.hex }
      ingress       = { enabled = false }
      additionalEnv = [
        { name = "LANGFUSE_INIT_ORG_ID", value = "my-org" },
        { name = "LANGFUSE_INIT_PROJECT_ID", value = "my-project" },
        { name = "LANGFUSE_INIT_PROJECT_PUBLIC_KEY", value = local.langfuse_public_key },
        { name = "LANGFUSE_INIT_PROJECT_SECRET_KEY", value = local.langfuse_secret_key },
        { name = "LANGFUSE_INIT_USER_EMAIL", value = var.admin_email },
        { name = "LANGFUSE_INIT_USER_PASSWORD", value = random_password.langfuse_admin.result },
        # Langfuse blocks LLM-connection base URLs that resolve to private/cluster IPs (SSRF protection).
        # The A3 evaluation lab points an LLM connection at the in-cluster LiteLLM service. The check runs
        # twice: when the connection is saved (langfuse-web) AND when an evaluator runs (langfuse-worker),
        # so the allow-list must be set on both. langfuse.additionalEnv reaches both Deployments.
        # (Workshop Studio sets this during provisioning; the lab page only patches langfuse-web by hand.)
        { name = "LANGFUSE_LLM_CONNECTION_WHITELISTED_HOST", value = "litellm.litellm.svc.cluster.local" },
      ]
      resources = {
        requests = { cpu = "1", memory = "2Gi" }
        limits   = { memory = "2Gi" }
      }
    }

    postgresql = {
      image = { registry = "public.ecr.aws", repository = "${local.ecr_mirror}/postgresql", tag = "17.5.0-debian-12-r8", pullPolicy = "IfNotPresent" }
      auth  = { username = "admin", password = random_password.langfuse_postgres.result }
      primary = {
        resources = { requests = { cpu = "125m", memory = "256Mi" }, limits = { memory = "256Mi" } }
      }
    }

    clickhouse = {
      image        = { registry = "public.ecr.aws", repository = "${local.ecr_mirror}/clickhouse", tag = "25.2.1-debian-12-r0", pullPolicy = "IfNotPresent" }
      auth         = { password = random_password.langfuse_clickhouse.result }
      replicaCount = 1
      resources = {
        requests = { cpu = "1", memory = "3Gi", "ephemeral-storage" = "50Mi" }
        limits   = { memory = "3Gi", "ephemeral-storage" = "2Gi" }
      }
      zookeeper = {
        image        = { registry = "public.ecr.aws", repository = "${local.ecr_mirror}/zookeeper", tag = "3.9.3-debian-12-r8", pullPolicy = "IfNotPresent" }
        replicaCount = 1
        resources = {
          requests = { cpu = "250m", memory = "384Mi", "ephemeral-storage" = "50Mi" }
          limits   = { memory = "384Mi", "ephemeral-storage" = "2Gi" }
        }
      }
    }

    redis = {
      image = { registry = "public.ecr.aws", repository = "${local.ecr_mirror}/valkey", tag = "8.0.2-debian-12-r2", pullPolicy = "IfNotPresent" }
      auth  = { password = random_password.langfuse_redis.result }
      primary = {
        resources = { requests = { cpu = "125m", memory = "256Mi" }, limits = { memory = "256Mi" } }
      }
    }

    s3 = {
      deploy         = false
      bucket         = aws_s3_bucket.langfuse.id
      region         = var.region
      endpoint       = ""
      forcePathStyle = false
      eventUpload    = { bucket = aws_s3_bucket.langfuse.id, prefix = "events/", region = var.region }
      batchExport    = { enabled = true, bucket = aws_s3_bucket.langfuse.id, prefix = "batch-exports/", region = var.region }
      mediaUpload    = { enabled = true, bucket = aws_s3_bucket.langfuse.id, prefix = "media/", region = var.region }
    }
  })]

  depends_on = [module.eks_auto_mode, aws_eks_pod_identity_association.langfuse]
}

# -------------------------------- LiteLLM ----------------------------------
resource "helm_release" "litellm" {
  name             = "litellm"
  namespace        = "litellm"
  create_namespace = true
  repository       = "oci://ghcr.io/berriai"
  chart            = "litellm-helm"
  version          = var.litellm_chart_version
  timeout          = 900

  values = [yamlencode({
    image = { tag = var.litellm_image_tag }
    # The LiteLLM image failed with "exec format error" on arm64 nodes (observed with v1.83.14).
    nodeSelector = { "kubernetes.io/arch" = "amd64" }
    global       = { security = { allowInsecureImages = true } }

    resources = {
      requests = { cpu = "1", memory = "2Gi" }
      limits   = { memory = "2Gi" }
    }

    redis = {
      enabled = true
      image   = { registry = "public.ecr.aws", repository = "${local.ecr_mirror}/redis", tag = "8.2.1-debian-12-r0", pullPolicy = "IfNotPresent" }
      master = {
        resources = { requests = { cpu = "125m", memory = "256Mi" }, limits = { memory = "256Mi" } }
      }
    }

    postgresql = {
      image = { registry = "public.ecr.aws", repository = "${local.ecr_mirror}/postgresql", tag = "17.5.0-debian-12-r8", pullPolicy = "IfNotPresent" }
      primary = {
        resources = { requests = { cpu = "125m", memory = "256Mi" }, limits = { memory = "256Mi" } }
      }
    }

    serviceAccount = { create = true }

    # Chart >= 1.10x runs schema migrations in a separate Job and then sets
    # DISABLE_SCHEMA_UPDATE=true on the proxy. Installed together with its bundled
    # PostgreSQL, that Job starts before the database accepts connections, exhausts its
    # retries and is garbage-collected (ttlSecondsAfterFinished), leaving an EMPTY schema:
    # /key/list and every Virtual Key / team / budget call then fail with
    # "table ... does not exist". With a single replica the proxy's own startup
    # `prisma db push` is simpler and race-free, so the Job is turned off.
    migrationJob = { enabled = false }

    masterkey = local.litellm_master_key
    ingress   = { enabled = false }

    envVars = {
      UI_USERNAME         = "admin"
      UI_PASSWORD         = random_password.litellm_ui.result
      LANGFUSE_HOST       = local.langfuse_url_internal
      LANGFUSE_PUBLIC_KEY = local.langfuse_public_key
      LANGFUSE_SECRET_KEY = local.langfuse_secret_key
    }

    proxy_config = merge({
      general_settings = {
        master_key                  = "os.environ/PROXY_MASTER_KEY"
        store_model_in_db           = true
        store_prompts_in_spend_logs = true
      }
      litellm_settings = {
        drop_params              = true
        callbacks                = ["langfuse"]
        success_callback         = ["langfuse"]
        failure_callback         = ["langfuse"]
        redact_user_api_key_info = true
        turn_off_message_logging = false
      }
      model_list = local.litellm_model_list
      }, var.enable_ab_routing ? {
      router_settings = {
        routing_strategy = "simple-shuffle"
        num_retries      = 2
        timeout          = 30
        fallbacks = [
          { "loan-processing-simple" = ["loan-processing-complex"] },
          { "loan-processing" = ["bedrock/claude-4.5-sonnet"] },
        ]
      }
    } : {})
  })]

  depends_on = [helm_release.langfuse, kubectl_manifest.vllm, aws_eks_pod_identity_association.litellm]
}

# ------------------------------- Open WebUI --------------------------------
resource "helm_release" "openwebui" {
  name             = "openwebui"
  namespace        = "openwebui"
  create_namespace = true
  repository       = "https://open-webui.github.io/helm-charts"
  chart            = "open-webui"
  version          = var.openwebui_chart_version
  timeout          = 900

  values = [yamlencode({
    nameOverride = "openwebui"
    ingress      = { enabled = false }

    openaiBaseApiUrl = "http://litellm.litellm:4000/v1"
    openaiApiKey     = local.litellm_master_key

    extraEnvVars = [
      { name = "WEBUI_ADMIN_EMAIL", value = var.admin_email },
      { name = "WEBUI_ADMIN_PASSWORD", value = random_password.openwebui_admin.result },
    ]

    ollama      = { enabled = false }
    pipelines   = { enabled = false }
    persistence = { enabled = true, size = var.openwebui_storage_size }

    resources = {
      requests = { cpu = "1", memory = "2Gi" }
      limits   = { memory = "2Gi" }
    }
  })]

  depends_on = [helm_release.litellm]
}
