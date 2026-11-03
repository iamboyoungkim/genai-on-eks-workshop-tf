# vLLM on Neuron (inf2). The images are pre-built (model baked in), so there is no
# HF token, PVC or compile job here - same as the upstream workshop config
# (compile=false). See manifests/vllm/ (copied from upstream components/llm-model/vllm).

locals {
  vllm_enabled = { for k, v in var.vllm_models : k => v if v }
}

resource "kubectl_manifest" "vllm_namespace" {
  yaml_body  = file("${path.module}/manifests/vllm/_namespace.yaml")
  depends_on = [module.eks_auto_mode]
}

data "kubectl_file_documents" "vllm" {
  for_each = local.vllm_enabled
  content  = file("${path.module}/manifests/vllm/${each.key}.yaml")
}

locals {
  vllm_docs = merge([
    for model, d in data.kubectl_file_documents.vllm : {
      for doc_key, body in d.manifests : "${model}|${doc_key}" => body
    }
  ]...)
}

resource "kubectl_manifest" "vllm" {
  for_each  = local.vllm_docs
  yaml_body = each.value

  # Do not block the whole apply on the (large) image pull + Neuron model load.
  # NOTE: for alekc/kubectl `wait` only concerns finalizers on delete; the rollout wait
  # is `wait_for_rollout` (default true) and times out after ~10 minutes, which aborted
  # the first apply while the multi-GB Neuron images were still being pulled.
  wait_for_rollout = false

  # KEDA / `make pause` change the replica count at runtime; do not reset it to the manifest's 1 on every apply.
  ignore_fields = ["spec.replicas"]

  depends_on = [kubectl_manifest.vllm_namespace, module.eks_auto_mode]
}
