# Adapted from upstream terraform/modules/eks-auto-mode/eks-addons.tf (see UPSTREAM.md).
# Kept:    default + neuron NodePools, EFS CSI driver, metrics-server, ebs/efs StorageClasses.
# Dropped: GPU NodePool/NodeClass (this workshop is inf2), ALB controller + internet-facing
#          IngressClasses, external-dns, ingress-nginx, LWS (nothing here is exposed publicly).

locals {
  efs_enabled = var.enable_efs
}

# ---------------------------------------------------------------------------
# NodePools (Auto Mode, karpenter.sh/v1)
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "nodepool_default" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      weight: 100
      limits:
        cpu: 100
      disruption:
        budgets:
          - nodes: 10%
        consolidateAfter: 30s
        consolidationPolicy: WhenEmptyOrUnderutilized
      template:
        spec:
          expireAfter: 336h
          nodeClassRef:
            group: eks.amazonaws.com
            kind: NodeClass
            name: default
          requirements:
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: eks.amazonaws.com/instance-category
              operator: In
              values: ["c", "m", "r"]
            - key: eks.amazonaws.com/instance-generation
              operator: Gt
              values: ["4"]
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64", "arm64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
          terminationGracePeriod: 24h0m0s
  YAML

  depends_on = [module.eks]
}

resource "kubectl_manifest" "nodepool_neuron" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: neuron
    spec:
      limits:
        aws.amazon.com/neuroncore: 50
      disruption:
        budgets:
          - nodes: 100%
            reasons:
              - Empty
          - nodes: 0%
            reasons:
              - Underutilized
              - Drifted
        consolidateAfter: 30s
        consolidationPolicy: WhenEmptyOrUnderutilized
      template:
        spec:
          expireAfter: 336h
          nodeClassRef:
            group: eks.amazonaws.com
            kind: NodeClass
            name: default
          requirements:
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: eks.amazonaws.com/instance-family
              operator: In
              values: ["inf2", "trn1", "trn2"]
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
          terminationGracePeriod: 24h0m0s
          taints:
            - key: aws.amazon.com/neuron
              value: "true"
              effect: NoSchedule
  YAML

  depends_on = [module.eks]
}

# ---------------------------------------------------------------------------
# EKS managed add-ons
# ---------------------------------------------------------------------------
resource "aws_iam_role" "efs_csi_driver" {
  count = local.efs_enabled ? 1 : 0

  name = "${module.eks.cluster_name}-${var.region}-efs-csi-driver"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "efs_csi_driver" {
  count = local.efs_enabled ? 1 : 0

  role       = aws_iam_role.efs_csi_driver[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "efs_csi_driver" {
  count = local.efs_enabled ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "efs-csi-controller-sa"
  role_arn        = aws_iam_role.efs_csi_driver[0].arn
}

data "aws_eks_addon_version" "efs_csi" {
  count = local.efs_enabled ? 1 : 0

  addon_name         = "aws-efs-csi-driver"
  kubernetes_version = module.eks.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "efs_csi" {
  count = local.efs_enabled ? 1 : 0

  cluster_name  = module.eks.cluster_name
  addon_name    = "aws-efs-csi-driver"
  addon_version = data.aws_eks_addon_version.efs_csi[0].version

  # Auto Mode has no nodes until a NodePool can launch one.
  depends_on = [kubectl_manifest.nodepool_default, aws_eks_pod_identity_association.efs_csi_driver]
}

data "aws_eks_addon_version" "metrics_server" {
  addon_name         = "metrics-server"
  kubernetes_version = module.eks.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "metrics-server"
  addon_version = data.aws_eks_addon_version.metrics_server.version

  configuration_values = jsonencode({
    resources = {
      requests = { cpu = "100m", memory = "256Mi" }
      limits   = { memory = "256Mi" }
    }
  })

  depends_on = [kubectl_manifest.nodepool_default]
}

# ---------------------------------------------------------------------------
# StorageClasses
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "storageclass_ebs" {
  yaml_body = <<-YAML
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: ebs
      annotations:
        storageclass.kubernetes.io/is-default-class: "true"
    provisioner: ebs.csi.eks.amazonaws.com
    volumeBindingMode: WaitForFirstConsumer
    parameters:
      type: gp3
  YAML

  ignore_fields = ["metadata.uid", "metadata.resourceVersion"]

  depends_on = [module.eks]
}

resource "kubectl_manifest" "storageclass_efs" {
  count = local.efs_enabled ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: efs
    provisioner: efs.csi.aws.com
    parameters:
      provisioningMode: efs-ap
      fileSystemId: ${var.efs_file_system_id}
      directoryPerms: "700"
  YAML

  ignore_fields = ["metadata.uid", "metadata.resourceVersion"]

  depends_on = [aws_eks_addon.efs_csi]
}
