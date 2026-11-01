# genai-on-eks-workshop-tf

Infrastructure for the [K8s Agentic Platform workshop](https://catalog.workshops.aws/k8sagenticplatform/) in a **single `terraform apply`**.
It ports the upstream [`aws-samples/sample-genai-on-eks-starter-kit`](https://github.com/aws-samples/sample-genai-on-eks-starter-kit)
`./cli demo-setup` flow (Terraform for the cluster, a Node.js CLI for Helm/kubectl) to plain Terraform.

## What gets installed (matches the workshop's `config.workshop.json`)

| Layer | Contents |
|---|---|
| Foundation | VPC (single NAT), EKS Auto Mode, `default` and `neuron` NodePools, EBS and EFS StorageClasses, metrics-server |
| Models | vLLM on Neuron (inf2.xlarge): `qwen3-8b-neuron`, `deepseek-r1-qwen3-8b-neuron` (pre-built images with the model baked in, no HF token needed) |
| Gateway | LiteLLM (the two vLLM models plus Bedrock `claude-4.5-sonnet`) |
| Observability | Langfuse (S3 + Pod Identity), wired to LiteLLM traces |
| UI | Open WebUI, connected to LiteLLM |

Not installed (not in the workshop config): Kong, Milvus/Qdrant/Chroma, TEI, MLflow/Phoenix, guardrails, n8n, OpenClaw, NVIDIA GPU NodePool.

## Usage

```bash
make tfvars         # write terraform.tfvars with your current public IP as the EKS API allow-list
make validate
make plan           # review it before applying (currently 100 resources to add)
make apply          # foreground; streams to the terminal and to logs/apply-<timestamp>.log
# or, fully detached (survives a closed terminal / tool timeouts):
make apply-bg && make logs        # `make logs-tail` prints the last lines and the EXIT= code
make kubeconfig && make status
make creds          # print the generated credentials
make port-forward   # binds 127.0.0.1 only: Open WebUI :8000, LiteLLM :4000, Langfuse :3000
make destroy
```

AWS credentials come from your default CLI configuration (or `AWS_PROFILE`); the default region is `us-west-2` (the upstream workshop region). Before choosing another region, make sure it has inf2 capacity and a free Elastic IP: the NAT gateway needs one, and `AddressLimitExceeded` aborts the apply half-way.
Requirements: Terraform >= 1.5, AWS CLI, kubectl. Helm is optional (debugging only).

### Saving cost between sessions: pause / resume

EKS Auto Mode nodes are Karpenter-managed EC2 instances and cannot be stopped or resized by hand. To stop paying for them,
scale the workloads to 0; empty nodes are removed automatically and all volumes are kept.

| Command | Stops | Keeps running | Time to bring back |
|---|---|---|---|
| `make pause-models` | the two inf2 vLLM models (the biggest cost) | LiteLLM, Langfuse, Open WebUI (Bedrock still works) | ~15-20 min |
| `make pause` | all workshop workloads | cluster, NAT gateway, EBS volumes, 1-2 small add-on nodes | ~15-20 min |
| `make resume` | (restores exactly what was paused; replica counts are stored on the workloads) | | |
| `make pause-status` | (shows each workload and the current nodes) | | |

Still billed while paused (rough estimate, verify against your own pricing): EKS control plane (~$0.10/h), NAT gateway (~$0.045/h
plus traffic), EBS volumes, and 1-2 small nodes. That is about $3-4 per day. If the stack stays idle for about a week or more,
`make destroy` is cheaper (state, generated passwords and data are lost).

`make apply` refuses to run while workloads are paused, because it would scale the models back up (override with `FORCE=1`).
Measured here: `pause-models` removed both inf2 nodes in ~3 min and `pause` went from 7 nodes to 2 in ~2 min. On `resume`, the
containers were running after ~8.5 min but the models only answered after ~16 min (inf2 node start, multi-GB image pull, Neuron model load).
The vLLM pods therefore have startup/readiness probes on `/health` and use `strategy: Recreate` (one pod fills a whole inf2 node, so a
rolling update would start extra inf2 nodes): `make resume` waits until the models are really ready (`RESUME_TIMEOUT`, default 1500s), and
LiteLLM only gets traffic routed to ready pods.

### Seeing the cluster in the AWS Console

The EKS Console lists nodes and workloads only for IAM principals that have an EKS access entry. Terraform grants one to
the identity that runs it automatically. If you sign in to the Console with a different role (typical with SSO or an `Admin`
role), put it in `terraform.tfvars`:

```hcl
cluster_admin_principal_arns = ["arn:aws:iam::<account-id>:role/Admin"]   # SSO roles: drop the aws-reserved/sso.amazonaws.com/<region>/ path
```

It receives `AmazonEKSClusterAdminPolicy`. Without it the Console shows "Your current IAM principal doesn't have access to Kubernetes objects".

The first deployment takes a while: an inf2 node must start, large images must be pulled and the Neuron model must load,
so the model pods are not Ready right away (`kubectl -n vllm get pods -w`; allow roughly 10 minutes). The vLLM manifests use
`wait_for_rollout = false` so `terraform apply` does not block on that (the provider's default rollout wait times out after about 10 minutes).

## Security defaults

- **Nothing is exposed publicly.** No Ingress, ALB or LoadBalancer is created and every Service is ClusterIP.
  Access the UIs through `make port-forward` (loopback only).
- **The public EKS API endpoint is restricted** to `api_allowed_cidrs`. There is no default and `0.0.0.0/0` is rejected.
- **All passwords and keys are generated** with `random_password` (the upstream fixed defaults such as `password123` are removed).
  They are stored in the Terraform state, so **never commit or share the state** (it is git-ignored).
  Move it to an encrypted remote backend if you need to share the stack.
- **Least-privilege Bedrock access:** the LiteLLM role can invoke only the configured inference profiles and foundation models
  (upstream allows invoke on `*`).
- **No static AWS keys:** the cluster uses EKS Pod Identity only.
- The Langfuse S3 bucket has all four Block Public Access settings and SSE enabled. It uses `force_destroy = true` for workshop convenience.

## Differences from upstream

Baseline: `aws-samples/sample-genai-on-eks-starter-kit` @ `0052c58` (2026-10-15, `main`).

| Area | Upstream | This repo |
|---|---|---|
| Install method | Terraform (cluster) + Node.js CLI (components) | Single Terraform root |
| Exposure | `internet-facing-alb` Ingress (a public ALB when `DOMAIN` is empty) | None, use port-forward |
| Credentials | Fixed defaults in `.env` | `random_password` |
| Langfuse chart | Unpinned (latest is now 2.x, which does not match the values schema) | Pinned to `1.5.41` |
| LiteLLM chart | Unpinned | Pinned to `1.106.6` |
| Open WebUI chart | `12.8.1` | `12.8.1` |
| GPU NodePool / NodeClass | Included | Removed (this workshop uses inf2) |
| ALB controller, external-dns, ingress-nginx, LWS | Included | Removed (nothing is exposed) |
| ECR pull-through cache policy on node role | Included | Removed |
| kubeconfig | Modifies `~/.kube/config` (local-exec) | `make kubeconfig` writes `./.kubeconfig` |

`modules/eks-auto-mode/` and `network.tf` are trimmed from upstream `terraform/`. `manifests/vllm/` is copied verbatim from upstream
`components/llm-model/vllm/model-*-neuron.template.yaml`. When upstream changes, diff those paths.

## Known caveats

- Moving to the Langfuse 2.x chart requires installing the ClickHouse operator and cert-manager first, plus a rewrite of the values.
- Neuron and Bedrock availability and quotas differ per region and account (on-demand Inf vCPU quota, Bedrock model access).
- To rename the stack, change the `name` variable only; all resource names derive from it.
