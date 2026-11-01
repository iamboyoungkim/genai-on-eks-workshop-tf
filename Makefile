# One-shot installer for the "K8s Agentic Platform" workshop stack on EKS Auto Mode.
# Uses the default AWS CLI credentials/region unless AWS_PROFILE / AWS_REGION are set.
#
# Logging: plan/apply/destroy stream to your terminal AND to logs/<op>-<timestamp>.log
# (logs/latest.log always points at the newest). The *-bg targets run fully detached,
# write only to the log file and end it with an "EXIT=<code>" line; follow them with
# `make logs` (live) or `make logs-tail` (last lines, non-blocking).

SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
export KUBECONFIG := $(CURDIR)/.kubeconfig
export TF_IN_AUTOMATION := 1

NAME   ?= $(shell terraform output -raw cluster_name 2>/dev/null || echo genai-on-eks)
REGION ?= $(shell terraform output -raw region 2>/dev/null || echo us-west-2)
LOG_DIR := logs
TF_FLAGS := -no-color -input=false

.PHONY: help tfvars init validate plan apply apply-bg destroy destroy-bg logs logs-tail kubeconfig creds status port-forward pause pause-models resume pause-status check-not-paused workshop-setup workshop-status pf-start pf-stop

help:
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/ -/'

tfvars: ## write terraform.tfvars with your current public IP for the EKS API allow-list
	@test ! -f terraform.tfvars || { echo "terraform.tfvars already exists - not overwriting"; exit 1; }
	@ip=$$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]') && \
	  printf 'api_allowed_cidrs = ["%s/32"]\n' "$$ip" > terraform.tfvars && cat terraform.tfvars

init: ## terraform init
	terraform init -input=false

validate: init ## fmt check + validate
	terraform fmt -check -recursive
	terraform validate

plan: init ## terraform plan -> tfplan (logged)
	@mkdir -p $(LOG_DIR); f=$(LOG_DIR)/plan-$$(date +%Y%m%d-%H%M%S).log; ln -sf $$(basename $$f) $(LOG_DIR)/latest.log; \
	  echo "log: $$f"; terraform plan $(TF_FLAGS) -out=tfplan 2>&1 | tee $$f

apply: check-not-paused ## apply the saved plan in the foreground (logged; run `make plan` first and review it)
	@mkdir -p $(LOG_DIR); f=$(LOG_DIR)/apply-$$(date +%Y%m%d-%H%M%S).log; ln -sf $$(basename $$f) $(LOG_DIR)/latest.log; \
	  echo "log: $$f"; terraform apply $(TF_FLAGS) tfplan 2>&1 | tee $$f

apply-bg: check-not-paused ## apply the saved plan fully detached (survives a closed terminal); follow with `make logs`
	@mkdir -p $(LOG_DIR); f=$(LOG_DIR)/apply-$$(date +%Y%m%d-%H%M%S).log; ln -sf $$(basename $$f) $(LOG_DIR)/latest.log; \
	  nohup bash -c 'terraform apply $(TF_FLAGS) tfplan; echo "EXIT=$$?"' > $$f 2>&1 < /dev/null & \
	  echo "started pid $$! -> $$f"

destroy: ## tear everything down (asks for confirmation, logged)
	@mkdir -p $(LOG_DIR); f=$(LOG_DIR)/destroy-$$(date +%Y%m%d-%H%M%S).log; ln -sf $$(basename $$f) $(LOG_DIR)/latest.log; \
	  echo "log: $$f"; terraform destroy -no-color 2>&1 | tee $$f

destroy-bg: ## detached destroy WITHOUT a prompt; requires CONFIRM=yes
	@test "$(CONFIRM)" = yes || { echo "refusing: run 'make destroy-bg CONFIRM=yes' to destroy without a prompt"; exit 1; }
	@mkdir -p $(LOG_DIR); f=$(LOG_DIR)/destroy-$$(date +%Y%m%d-%H%M%S).log; ln -sf $$(basename $$f) $(LOG_DIR)/latest.log; \
	  nohup bash -c 'terraform destroy $(TF_FLAGS) -auto-approve; echo "EXIT=$$?"' > $$f 2>&1 < /dev/null & \
	  echo "started pid $$! -> $$f"

check-not-paused:
	@if [ -z "$(FORCE)" ] && scripts/pause.sh is-paused; then \
	  echo "Workloads are paused: 'terraform apply' would scale the vLLM models back up."; \
	  echo "Run 'make resume' first, or 'make apply FORCE=1' if that is what you want."; exit 1; fi

pause: ## scale ALL workshop workloads to 0 (nodes disappear, volumes kept); resume with `make resume`
	@mkdir -p $(LOG_DIR); f=$(LOG_DIR)/pause-$$(date +%Y%m%d-%H%M%S).log; ln -sf $$(basename $$f) $(LOG_DIR)/latest.log; \
	  scripts/pause.sh pause 2>&1 | tee $$f

pause-models: ## scale only the inf2 vLLM models to 0 (keeps LiteLLM/Langfuse/Open WebUI; Bedrock keeps working)
	@mkdir -p $(LOG_DIR); f=$(LOG_DIR)/pause-$$(date +%Y%m%d-%H%M%S).log; ln -sf $$(basename $$f) $(LOG_DIR)/latest.log; \
	  scripts/pause.sh pause-models 2>&1 | tee $$f

resume: ## restore everything that `pause` / `pause-models` stopped (waits until the models are ready, ~15-20 min)
	@mkdir -p $(LOG_DIR); f=$(LOG_DIR)/resume-$$(date +%Y%m%d-%H%M%S).log; ln -sf $$(basename $$f) $(LOG_DIR)/latest.log; \
	  scripts/pause.sh resume 2>&1 | tee $$f

workshop-setup: ## prepare what the workshop labs expect (starter-kit checkout, .env, values.rendered.yaml)
	@scripts/workshop.sh setup

workshop-status: ## show the workshop workspace and which loopback ports are served
	@scripts/workshop.sh status

pf-start: ## keep Open WebUI :8000, LiteLLM :4000, Langfuse :3000 reachable on 127.0.0.1 (detached, auto-restarting)
	@scripts/workshop.sh pf-start

pf-stop: ## stop the detached port-forwards started by pf-start
	@scripts/workshop.sh pf-stop

pause-status: ## show replicas / paused state of every workload and the current nodes
	@scripts/pause.sh status

logs: ## follow the newest log live (Ctrl-C to stop; does not stop terraform)
	@tail -n 40 -f $(LOG_DIR)/latest.log

logs-tail: ## print the last 40 lines of the newest log and whether it has finished
	@tail -n 40 $(LOG_DIR)/latest.log; echo; grep -E '^EXIT=' $(LOG_DIR)/latest.log || echo "(still running or foreground run)"

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
