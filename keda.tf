# A3 "monitoring-scaling" lab, step 2: event-driven autoscaling of the Qwen vLLM Deployment with KEDA
# (opt-in, var.enable_vllm_autoscaling + var.enable_monitoring).
#
#   KEDA --(SigV4, Pod Identity)--> Amazon Managed Prometheus: sum(vllm:num_requests_waiting) --> HPA --> qwen3-8b-neuron
#   Auto Mode provisions one more inf2.xlarge node per extra replica.
#
# Deviations from the lab text (all found while verifying it):
#  - the query is sum(...{model_name="qwen3-8b-neuron"}), not avg(...{namespace="vllm"}): with the default AverageValue
#    target, an average does not grow with load and the other model (deepseek) would pollute the signal
#  - the Pod Identity association is created, and given time to propagate, before KEDA starts (otherwise the operator
#    has no AWS credentials until restarted)
#  - the unused TriggerAuthentication in the litellm namespace is not created (LiteLLM uses no KEDA trigger)

locals {
  keda = (var.enable_vllm_autoscaling && var.enable_monitoring) ? { on = true } : {}
}

resource "aws_iam_role" "keda" {
  for_each           = local.keda
  name               = "${var.name}-${var.region}-keda-amp"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy" "keda" {
  for_each = local.keda
  role     = aws_iam_role.keda["on"].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["aps:QueryMetrics", "aps:GetSeries", "aps:GetLabels", "aps:GetMetricMetadata"]
      Resource = aws_prometheus_workspace.this["on"].arn
    }]
  })
}

resource "aws_eks_pod_identity_association" "keda" {
  for_each        = local.keda
  cluster_name    = module.eks_auto_mode.cluster_name
  namespace       = "keda"
  service_account = "keda-operator"
  role_arn        = aws_iam_role.keda["on"].arn
}

# The EKS Pod Identity webhook needs a few seconds to see a new association; a pod created immediately after it
# starts without credentials (observed with the ADOT collector).
resource "terraform_data" "keda_identity_propagation" {
  for_each   = local.keda
  depends_on = [aws_eks_pod_identity_association.keda, aws_iam_role_policy.keda]
  provisioner "local-exec" {
    command = "sleep 60"
  }
}

resource "helm_release" "keda" {
  for_each         = local.keda
  name             = "keda"
  namespace        = "keda"
  create_namespace = true
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.21.0"
  timeout          = 600

  depends_on = [terraform_data.keda_identity_propagation, module.eks_auto_mode]
}

resource "kubectl_manifest" "keda_trigger_auth" {
  for_each = local.keda
  yaml_body = yamlencode({
    apiVersion = "keda.sh/v1alpha1"
    kind       = "TriggerAuthentication"
    metadata   = { name = "amp-auth", namespace = "vllm" }
    spec       = { podIdentity = { provider = "aws" } }
  })
  depends_on = [helm_release.keda, kubectl_manifest.vllm_namespace]
}

resource "kubectl_manifest" "keda_scaledobject_qwen" {
  for_each = local.keda
  yaml_body = yamlencode({
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"
    metadata   = { name = "vllm-scaledobject", namespace = "vllm" }
    spec = {
      scaleTargetRef  = { name = "qwen3-8b-neuron" }
      minReplicaCount = 1
      maxReplicaCount = var.vllm_max_replicas
      pollingInterval = 15
      cooldownPeriod  = 300
      triggers = [{
        type = "prometheus"
        metadata = {
          serverAddress = local.amp_url # no trailing slash, or KEDA builds "//api/v1/query" and AMP answers 403
          query         = "sum(vllm:num_requests_waiting{model_name=\"qwen3-8b-neuron\"})"
          threshold     = "3"
          awsRegion     = var.region
        }
        authenticationRef = { name = "amp-auth" }
      }]
    }
  })
  depends_on = [kubectl_manifest.keda_trigger_auth, kubectl_manifest.vllm]
}
