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

### Following the workshop labs against this stack

The labs assume an event-provisioned environment (the starter-kit at `/workshop`, `/workshop/.env`, public Ingress URLs, Terraform
outputs next to the components). This stack exposes nothing publicly, so a small compatibility layer rebuilds what the labs need locally:

```bash
make workshop-setup   # starter-kit @ the pinned commit -> .workshop/starter-kit, its .env, components/ai-gateway/litellm/values.rendered.yaml
make pf-start         # detached, auto-restarting port-forwards on 127.0.0.1: Open WebUI :8000, LiteLLM :4000, Langfuse :3000, Grafana :3001 (if enabled)
eval "$(scripts/workshop.sh env)"   # in each terminal you follow the labs in (bash or zsh)
make workshop-status  # what is set up / listening; `make pf-stop` stops the forwards
```

After `eval`, the lab commands work as written:

- `source /workshop/.env` / `$LITELLM_MASTER_KEY`, `$REGION`, `$EKS_CLUSTER_NAME`, `$LANGFUSE_*`: set from `.workshop/starter-kit/.env`.
  The labs append `AGENT_KEY` there; it survives `make workshop-setup`.
- `kubectl get ingress -n litellm litellm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'` (also langfuse, openwebui):
  a `kubectl` shim answers exactly this lookup with `127.0.0.1:<port>`; every other `kubectl` call is untouched.
- `terraform output -raw langfuse_bucket_name` / `langfuse_s3_role_arn` run from `components/o11y/langfuse`: a `terraform` shim forwards them
  to this stack (the A2 `deploy-workshop-app.sh` then runs without prompts).
- A1 "add GPT-OSS-20B": edit `$WORKSHOP_DIR/components/ai-gateway/litellm/values.rendered.yaml`, then run the lab's `helm upgrade`.
  The LiteLLM role is already allowed to invoke `openai.gpt-oss-20b-1:0` (`bedrock_extra_model_ids`). The change lives only in the Helm release:
  to keep it across `terraform apply`, add `"gpt-oss-20b" = "openai.gpt-oss-20b-1:0"` to `bedrock_models` in `terraform.tfvars`.
- The pages' absolute `/workshop/...` paths: use `$WORKSHOP_DIR/...`, or make them literal with `sudo ln -s "$PWD/.workshop/starter-kit" /workshop`.

`make workshop-setup` never overwrites an edited `values.rendered.yaml` (regenerate with `FORCE_VALUES=1 make workshop-setup`).
Everything under `.workshop/` is git-ignored and holds credentials (mode 600/700).
Not provided: External Secrets and KubeRay (A4), the VSC IDE, and the GPU node pool. KEDA, AMP/ADOT and Grafana are available as opt-in add-ons (next section).

### Optional add-ons for the A3 labs

All three are **off by default** (set them in `terraform.tfvars`, then `make apply`). They exist because the labs install these by hand
from manifests that are missing upstream or that do not work as written in this stack.

| Variable | Default | What it adds |
|---|---|---|
| `enable_ab_routing` | `false` | LiteLLM model groups for the model-routing lab: `loan-processing` (Claude weight 8 / Qwen weight 2), `loan-processing-simple` (Qwen), `loan-processing-complex` (Claude), with fallbacks. |
| `enable_monitoring` | `false` | Amazon Managed Prometheus workspace, neuron-monitor DaemonSet, ADOT collector and an in-cluster Grafana (ClusterIP) with a vLLM/Neuron dashboard. IAM roles are scoped to that one workspace. |
| `enable_vllm_autoscaling` | `false` | KEDA plus a ScaledObject that scales the Qwen deployment on `sum(vllm:num_requests_waiting)`. Needs `enable_monitoring = true`. |
| `vllm_max_replicas` | `3` | Upper bound for that ScaledObject (1-5). **Each replica is one more inf2.xlarge node**, so this is also your cost cap. |

```hcl
# terraform.tfvars
enable_ab_routing       = true
enable_monitoring       = true
enable_vllm_autoscaling = true
vllm_max_replicas       = 3
```

- **A/B routing.** The `loan-processing` group needs a virtual key that lists it in its models:
  `AGENT_KEY_ALIAS=agent-key-ab AGENT_KEY_MODELS="bedrock/claude-4.5-sonnet,vllm/qwen3-8b-neuron,vllm/deepseek-r1-qwen3-8b-neuron,loan-processing,loan-processing-simple,loan-processing-complex" scripts/workshop.sh agent-key`.
  Check the split with `scripts/ab-test.sh 100` (counts the answering backend per request via the `x-litellm-model-id` header; use a second
  argument such as `loan-processing-simple` for the other groups). Use at least 100 requests: 20 can easily show 15/5 or 17/3.
- **Monitoring.** Grafana is reached with `make pf-start` (port-forward on `127.0.0.1:3001`), user `admin`, password from
  `terraform output -json credentials | jq -r .grafana_password`. Right after a fresh apply the ADOT/Grafana pods may start before the EKS Pod
  Identity association has propagated (`no EC2 IMDS role found`); `kubectl -n adot rollout restart deploy/adot-collector` (and `-n grafana`) fixes it.
  On Inferentia `vllm:gpu_cache_usage_perc` stays 0 (the Neuron plugin uses static per-sequence KV slots), so the dashboard shows batch-slot
  occupancy instead. There are no alerts based on kube-state-metrics (it is not installed).
- **Autoscaling.** A new replica takes 13-17 minutes to become ready on a fresh node (multi-GB Neuron image pull plus model load), and Auto Mode
  removes empty inf2 nodes within minutes, so short load tests mostly measure the cold start. Run the load for 15-20 minutes
  (`hey -z 20m -c 8 -t 180 ...`; its default 20 s client timeout makes nearly every request fail). `make pause` pauses the ScaledObject too, and
  Terraform ignores `spec.replicas` on the vLLM Deployments so an apply does not reset the autoscaled count.

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
| LiteLLM image | `main-v1.81.3-stable` (`finish_reason=tool_calls` for `json_schema`, which breaks the Langfuse evaluator) | `main-v1.83.14-stable`, pinned to amd64 |
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
