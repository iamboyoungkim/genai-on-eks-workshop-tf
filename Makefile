# One-shot installer for the "K8s Agentic Platform" workshop stack on EKS Auto Mode.
# Uses the default AWS CLI credentials/region unless AWS_PROFILE / AWS_REGION are set.

SHELL := /bin/bash
export KUBECONFIG := $(CURDIR)/.kubeconfig
NAME   ?= $(shell terraform output -raw cluster_name 2>/dev/null || echo genai-on-eks)
REGION ?= $(shell terraform output -raw region 2>/dev/null || echo ap-northeast-2)

.PHONY: help tfvars init validate plan apply destroy kubeconfig creds status port-forward

help:
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/ -/'

tfvars: ## write terraform.tfvars with your current public IP for the EKS API allow-list
	@test ! -f terraform.tfvars || { echo "terraform.tfvars already exists - not overwriting"; exit 1; }
	@ip=$$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]') && \
	  printf 'api_allowed_cidrs = ["%s/32"]\n' "$$ip" > terraform.tfvars && cat terraform.tfvars

init: ## terraform init
	terraform init

validate: init ## fmt check + validate
	terraform fmt -check -recursive
	terraform validate

plan: init ## terraform plan -> tfplan
	terraform plan -out=tfplan

apply: ## apply the saved plan (run `make plan` first and review it)
	terraform apply tfplan

destroy: ## tear everything down (asks for confirmation)
	terraform destroy

kubeconfig: ## project-local kubeconfig (./.kubeconfig), leaves ~/.kube/config untouched
	aws eks update-kubeconfig --region $(REGION) --name $(NAME) --kubeconfig $(CURDIR)/.kubeconfig

creds: ## print generated credentials (sensitive)
	@terraform output -json credentials | python3 -m json.tool

status: ## pods and Neuron nodes
	kubectl get nodes -L node.kubernetes.io/instance-type
	kubectl get pods -A | grep -E 'vllm|litellm|langfuse|openwebui|NAMESPACE'

port-forward: ## forward the UIs to 127.0.0.1 only (Ctrl-C to stop)
	@trap 'kill 0' INT TERM; \
	kubectl -n openwebui port-forward --address 127.0.0.1 svc/openwebui 8000:80 & \
	kubectl -n litellm   port-forward --address 127.0.0.1 svc/litellm   4000:4000 & \
	kubectl -n langfuse  port-forward --address 127.0.0.1 svc/langfuse-web 3000:3000 & \
	wait
