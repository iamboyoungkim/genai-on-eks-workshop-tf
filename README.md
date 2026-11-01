# genai-on-eks-workshop-tf

[K8s Agentic Platform 워크샵](https://catalog.workshops.aws/k8sagenticplatform/)의 인프라를 **`terraform apply` 한 번**으로 올리는 구성입니다.
업스트림 [`aws-samples/sample-genai-on-eks-starter-kit`](https://github.com/aws-samples/sample-genai-on-eks-starter-kit)의
`./cli demo-setup` (Terraform + Node.js CLI + Helm/kubectl)을 순수 Terraform으로 옮겼습니다.

## 설치되는 것 (워크샵 기준 `config.workshop.json`과 동일)

| 레이어 | 내용 |
|---|---|
| 기반 | VPC(NAT 1개), EKS Auto Mode, NodePool(default / neuron), EBS·EFS StorageClass, metrics-server |
| 모델 | vLLM on Neuron(inf2.xlarge): `qwen3-8b-neuron`, `deepseek-r1-qwen3-8b-neuron` (모델 내장 이미지, HF 토큰 불필요) |
| 게이트웨이 | LiteLLM (vLLM 2종 + Bedrock `claude-4.5-sonnet`) |
| 관측 | Langfuse (S3 + Pod Identity), LiteLLM trace 연동 |
| UI | Open WebUI (LiteLLM 연결) |

설치하지 않는 것: Kong, Milvus/Qdrant/Chroma, TEI, MLflow/Phoenix, guardrail, n8n, OpenClaw, GPU(NVIDIA) NodePool 등 워크샵 설정에 없는 항목.

## 사용법

```bash
make tfvars     # 현재 공인 IP를 EKS API 허용 CIDR로 terraform.tfvars에 기록
make validate
make plan       # 반드시 검토 (현재 100 resources to add)
make apply
make kubeconfig && make status
make creds      # 생성된 계정 정보 출력
make port-forward   # 127.0.0.1 로만 바인딩 (Open WebUI :8000, LiteLLM :4000, Langfuse :3000)
make destroy
```

AWS 자격증명은 기본 CLI 설정(또는 `AWS_PROFILE`)을 사용하고 기본 리전은 `ap-northeast-2`입니다.
필수 도구: terraform ≥ 1.5, aws cli, kubectl, helm(선택, 디버깅용).

첫 배포는 inf2 노드 기동 + 대용량 이미지 pull + 모델 로드 때문에 모델 Pod가 Ready가 되기까지 시간이 걸립니다
(`kubectl -n vllm get pods -w`). vLLM 매니페스트는 apply를 막지 않도록 `wait = false`입니다.

## 보안 기본값

- 외부 노출 없음: Ingress/ALB/LoadBalancer를 만들지 않고 모든 Service는 ClusterIP입니다. 접속은 `make port-forward`(loopback)로만 합니다.
- EKS API 퍼블릭 엔드포인트는 `api_allowed_cidrs`로 제한됩니다. 기본값이 없고 `0.0.0.0/0`은 거부됩니다.
- 모든 비밀번호/키는 `random_password`로 생성합니다(업스트림의 `password123` 등 고정값 제거). 값은 Terraform state에 저장되므로
  **state를 커밋/공유하지 마세요**(.gitignore 처리됨). 공유가 필요하면 암호화된 원격 backend로 옮기세요.
- LiteLLM의 Bedrock 권한은 설정한 모델(inference profile / foundation model)로만 제한합니다(업스트림은 `*`).
- AWS 접근은 EKS Pod Identity만 사용하며 정적 키는 없습니다.
- Langfuse S3 버킷은 Block Public Access 4종 + SSE이며, 워크샵 편의상 `force_destroy = true`입니다.

## 업스트림 기준과 차이

기준: `aws-samples/sample-genai-on-eks-starter-kit` @ `0052c58` (2026-10-15, main).

| 항목 | 업스트림 | 여기 |
|---|---|---|
| 설치 방식 | Terraform(클러스터) + Node.js CLI(컴포넌트) | 단일 Terraform |
| 노출 | `internet-facing-alb` Ingress (DOMAIN 비면 공개 ALB) | 없음, port-forward |
| 계정/키 | `.env` 고정 기본값 | `random_password` |
| Langfuse 차트 | 버전 미고정 (현재 latest=2.x, values 스키마 불일치) | `1.5.41` 고정 |
| LiteLLM 차트 | 미고정 | `1.106.6` 고정 |
| Open WebUI 차트 | 12.8.1 | 12.8.1 |
| GPU NodePool/NodeClass | 있음 | 제외 (inf2 워크샵) |
| ALB controller, external-dns, ingress-nginx, LWS | 있음 | 제외 (노출 없음) |
| EKS 노드 IAM의 ECR pull-through cache | 있음 | 제외 |
| kubeconfig | `~/.kube/config` 수정 (local-exec) | `make kubeconfig` → `./.kubeconfig` |

`modules/eks-auto-mode/`와 `network.tf`는 업스트림 `terraform/`에서 가져와 줄인 것이고, `manifests/vllm/`은 업스트림
`components/llm-model/vllm/model-*-neuron.template.yaml`을 그대로 복사한 것입니다. 업스트림이 바뀌면 해당 경로를 diff 하세요.

## 알려진 주의점

- Langfuse 2.x 차트로 올리려면 ClickHouse operator + cert-manager 선행 설치와 values 재작성이 필요합니다.
- Neuron/Bedrock 가용성과 쿼터는 리전/계정마다 다릅니다(Inf 온디맨드 vCPU 쿼터, Bedrock 모델 접근).
- 클러스터 이름을 바꾸면 `name` 변수 하나만 바꾸면 됩니다(리소스 이름이 모두 파생됩니다).
