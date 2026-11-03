# A3 "monitoring-scaling" lab, step 1: infrastructure monitoring (opt-in, var.enable_monitoring).
#
#   vLLM :8000/metrics + neuron-monitor :8000 --(ADOT collector, SigV4)--> Amazon Managed Prometheus
#   Grafana (in-cluster, ClusterIP) --(SigV4 via Pod Identity)--> AMP
#
# The workshop deploys this with kubectl/aws CLI from manifests that are missing from the upstream repo
# (module4/monitoring/*.yaml), so the manifests here are written from the lab text + the Neuron SDK reference
# DaemonSet. Everything is private: no Ingress, Grafana is reached with kubectl port-forward.

locals {
  monitoring = var.enable_monitoring ? { on = true } : {}

  amp_endpoint     = try(aws_prometheus_workspace.this["on"].prometheus_endpoint, "")
  amp_url          = trimsuffix(local.amp_endpoint, "/")
  amp_remote_write = "${local.amp_endpoint}api/v1/remote_write"
}

resource "aws_prometheus_workspace" "this" {
  for_each = local.monitoring
  alias    = "${var.name}-metrics"
}

# ---------------------------- IAM (EKS Pod Identity) ------------------------
resource "aws_iam_role" "adot" {
  for_each           = local.monitoring
  name               = "${var.name}-${var.region}-adot-amp"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy" "adot" {
  for_each = local.monitoring
  role     = aws_iam_role.adot["on"].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["aps:RemoteWrite"]
      Resource = aws_prometheus_workspace.this["on"].arn # this workspace only, not the broad managed policy
    }]
  })
}

resource "aws_eks_pod_identity_association" "adot" {
  for_each        = local.monitoring
  cluster_name    = module.eks_auto_mode.cluster_name
  namespace       = "adot"
  service_account = "adot-collector"
  role_arn        = aws_iam_role.adot["on"].arn
}

resource "aws_iam_role" "grafana" {
  for_each           = local.monitoring
  name               = "${var.name}-${var.region}-grafana-amp"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy" "grafana" {
  for_each = local.monitoring
  role     = aws_iam_role.grafana["on"].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["aps:QueryMetrics", "aps:GetSeries", "aps:GetLabels", "aps:GetMetricMetadata"]
      Resource = aws_prometheus_workspace.this["on"].arn
    }]
  })
}

resource "aws_eks_pod_identity_association" "grafana" {
  for_each        = local.monitoring
  cluster_name    = module.eks_auto_mode.cluster_name
  namespace       = "grafana"
  service_account = "grafana"
  role_arn        = aws_iam_role.grafana["on"].arn
}

# ------------------------------- Kubernetes ---------------------------------
resource "kubectl_manifest" "monitoring_ns" {
  for_each = var.enable_monitoring ? toset(["adot", "grafana", "neuron-monitor"]) : toset([])
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = each.key }
  })
  depends_on = [module.eks_auto_mode]
}

# neuron-monitor DaemonSet
data "kubectl_file_documents" "neuron_monitor" {
  for_each = local.monitoring
  content  = file("${path.module}/manifests/monitoring/neuron-monitor.yaml")
}

resource "kubectl_manifest" "neuron_monitor" {
  for_each         = var.enable_monitoring ? data.kubectl_file_documents.neuron_monitor["on"].manifests : {}
  yaml_body        = each.value
  wait_for_rollout = false
  depends_on       = [kubectl_manifest.monitoring_ns]
}

# ADOT collector. The Pod Identity association must exist before the pod starts (otherwise it has no AWS
# credentials until restarted), hence the explicit depends_on.
# Parse the raw file (known at plan time) and substitute the placeholders per document, so the for_each keys
# do not depend on the not-yet-known AMP endpoint.
data "kubectl_file_documents" "adot" {
  for_each = local.monitoring
  content  = file("${path.module}/manifests/monitoring/adot-collector.yaml")
}

resource "kubectl_manifest" "adot" {
  for_each         = var.enable_monitoring ? data.kubectl_file_documents.adot["on"].manifests : {}
  yaml_body        = replace(replace(each.value, "__AMP_REMOTE_WRITE__", local.amp_remote_write), "__REGION__", var.region)
  wait_for_rollout = false
  depends_on       = [kubectl_manifest.monitoring_ns, aws_eks_pod_identity_association.adot, aws_iam_role_policy.adot]
}

# Grafana
resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "kubectl_manifest" "grafana_secret" {
  for_each = local.monitoring
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata   = { name = "grafana-admin", namespace = "grafana" }
    type       = "Opaque"
    stringData = { password = random_password.grafana_admin.result }
  })
  sensitive_fields = ["stringData"]
  depends_on       = [kubectl_manifest.monitoring_ns]
}

resource "kubectl_manifest" "grafana_dashboards" {
  for_each = local.monitoring
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata   = { name = "grafana-dashboards", namespace = "grafana" }
    data       = { "dashboard-vllm-neuron.json" = file("${path.module}/manifests/monitoring/dashboard-vllm-neuron.json") }
  })
  depends_on = [kubectl_manifest.monitoring_ns]
}

data "kubectl_file_documents" "grafana" {
  for_each = local.monitoring
  content  = file("${path.module}/manifests/monitoring/grafana.yaml")
}

resource "kubectl_manifest" "grafana" {
  for_each         = var.enable_monitoring ? data.kubectl_file_documents.grafana["on"].manifests : {}
  yaml_body        = replace(replace(each.value, "__AMP_URL__", local.amp_url), "__REGION__", var.region)
  wait_for_rollout = false
  depends_on = [
    kubectl_manifest.monitoring_ns,
    kubectl_manifest.grafana_secret,
    kubectl_manifest.grafana_dashboards,
    aws_eks_pod_identity_association.grafana,
    aws_iam_role_policy.grafana,
  ]
}
