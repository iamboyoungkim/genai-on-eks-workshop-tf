#!/usr/bin/env bash
# Pause / resume the workshop workloads to save cost without destroying the stack.
#
# EKS Auto Mode nodes are Karpenter-managed EC2 instances: they cannot be stopped or
# resized by hand. Instead we scale the workloads to 0; empty nodes are then removed by
# the NodePools (consolidateAfter 30s). Persistent volumes are kept. The original replica
# count is stored on each workload as the annotation `genai-paused-replicas`, so `resume`
# restores exactly what was running and needs no local state file.
#
# Still billed while paused: EKS control plane, NAT gateway, EBS volumes, 1-2 small nodes
# for the kube-system add-ons.
#
# Usage: scripts/pause.sh pause | pause-models | resume | status | is-paused
# Works with the macOS default bash 3.2 (no mapfile / associative arrays).
set -euo pipefail

cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-$PWD/.kubeconfig}"

ANN="genai-paused-replicas"
NS_ALL="openwebui litellm langfuse vllm"   # pause order: consumers first
NS_MODELS="vllm"
RESUME_TIMEOUT="${RESUME_TIMEOUT:-1500s}"  # inf2 node + multi-GB image pull + model load
KC="kubectl --request-timeout=20s"

die() { echo "error: $*" >&2; exit 2; }

need_cluster() {
  [ -f "$KUBECONFIG" ] || die "no kubeconfig at $KUBECONFIG - run 'make kubeconfig' first"
  $KC get ns >/dev/null 2>&1 || die "cannot reach the cluster (is your IP in api_allowed_cidrs? credentials valid?)"
}

# "<Kind> <name> <replicas> <paused-replicas-annotation>" per workload
list_ns() {
  $KC -n "$1" get deploy,sts -o \
    jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{" "}{.spec.replicas}{" "}{.metadata.annotations.genai-paused-replicas}{"\n"}{end}' \
    2>/dev/null || true
}

res_of() { echo "$1" | tr 'A-Z' 'a-z'; }  # Deployment -> deployment, StatefulSet -> statefulset

# KEDA would scale a paused (0 replicas) target straight back up, so pause its ScaledObjects first.
keda_pause_ns()  { $KC -n "$1" annotate scaledobject --all autoscaling.keda.sh/paused=true --overwrite >/dev/null 2>&1 || true; }
keda_resume_ns() { $KC -n "$1" annotate scaledobject --all autoscaling.keda.sh/paused- >/dev/null 2>&1 || true; }

pause_ns() {
  local ns="$1" kind name rep ann res
  keda_pause_ns "$ns"
  list_ns "$ns" | while read -r kind name rep ann; do
    [ -n "${name:-}" ] || continue
    res="$(res_of "$kind")"
    if [ "${rep:-0}" -gt 0 ]; then
      $KC -n "$ns" annotate "$res/$name" "$ANN=$rep" --overwrite >/dev/null
      $KC -n "$ns" scale "$res/$name" --replicas=0 >/dev/null
      echo "paused   $ns/$res/$name (was $rep)"
    else
      echo "already  $ns/$res/$name (0 replicas)"
    fi
  done
}

wait_nodes_gone() {
  local selector="$1" label="$2" i n
  echo "waiting for $label nodes to be removed (up to ~6 min)..."
  for i in $(seq 1 36); do
    n="$($KC get nodes $selector --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" = "0" ] && { echo "$label nodes: 0"; return 0; }
    sleep 10
  done
  echo "warning: $n $label node(s) still present after the wait (they may still be draining)"
}

show_nodes() {
  echo "nodes now:"
  $KC get nodes -L node.kubernetes.io/instance-type,karpenter.sh/nodepool --no-headers 2>/dev/null \
    | awk '{print "  " $1, $(NF-1), $NF}' || true
}

do_pause() {
  local scope="$1" ns
  need_cluster
  if [ "$scope" = models ]; then
    for ns in $NS_MODELS; do pause_ns "$ns"; done
    wait_nodes_gone "-l karpenter.sh/nodepool=neuron" "inf2 (neuron)"
  else
    for ns in $NS_ALL; do pause_ns "$ns"; done
    wait_nodes_gone "-l karpenter.sh/nodepool=neuron" "inf2 (neuron)"
    sleep 45   # let the general nodes drain and consolidate
  fi
  show_nodes
  echo "paused. Resume with: make resume   (do NOT run 'make apply' while paused)"
}

# Scale up one tier. $1 = "sts" | "deploy-vllm" | "deploy-other"
scale_up_tier() {
  local tier="$1" ns kind name rep ann res
  for ns in langfuse litellm openwebui vllm; do
    list_ns "$ns" | while read -r kind name rep ann; do
      [ -n "${ann:-}" ] || continue
      res="$(res_of "$kind")"
      case "$tier" in
        sts)          [ "$res" = statefulset ] || continue ;;
        deploy-vllm)  [ "$res" = deployment ] && [ "$ns" = vllm ] || continue ;;
        deploy-other) [ "$res" = deployment ] && [ "$ns" != vllm ] || continue ;;
      esac
      $KC -n "$ns" scale "$res/$name" --replicas="$ann" >/dev/null
      $KC -n "$ns" annotate "$res/$name" "$ANN-" >/dev/null
      echo "resumed  $ns/$res/$name -> $ann"
    done
  done
}

wait_rollouts() {
  local kindsel="$1" ns kind name rep ann res
  for ns in langfuse litellm openwebui vllm; do
    list_ns "$ns" | while read -r kind name rep ann; do
      [ -n "${name:-}" ] || continue
      res="$(res_of "$kind")"
      case "$kindsel" in
        sts)    [ "$res" = statefulset ] || continue ;;
        deploy) [ "$res" = deployment ] || continue ;;
      esac
      [ "${rep:-0}" -gt 0 ] || continue
      echo "waiting  $ns/$res/$name"
      $KC -n "$ns" rollout status "$res/$name" --timeout="$RESUME_TIMEOUT" | tail -1
    done
  done
}

do_resume() {
  need_cluster
  # Start the slow part (inf2 nodes + image pull + model load) first, in parallel with the rest.
  scale_up_tier deploy-vllm
  keda_resume_ns vllm   # hand the replica count back to KEDA (it keeps the restored count until the next poll)
  scale_up_tier sts
  wait_rollouts sts
  scale_up_tier deploy-other
  wait_rollouts deploy
  show_nodes
  echo "resumed. Check models with: make status"
}

paused_count() {
  local ns kind name rep ann n=0
  for ns in $NS_ALL; do
    n=$(( n + $(list_ns "$ns" | awk 'NF>=4{c++} END{print c+0}') ))
  done
  echo "$n"
}

case "${1:-}" in
  pause)        do_pause all ;;
  pause-models) do_pause models ;;
  resume)       do_resume ;;
  is-paused)    # quiet; exit 0 only when we can reach the cluster and something is paused
    [ -f "$KUBECONFIG" ] || exit 1
    $KC get ns >/dev/null 2>&1 || exit 1
    [ "$(paused_count)" -gt 0 ] ;;
  status)
    need_cluster
    for ns in $NS_ALL; do
      list_ns "$ns" | while read -r kind name rep ann; do
        [ -n "${name:-}" ] || continue
        if [ -n "${ann:-}" ]; then s="PAUSED (was $ann)"; else s="replicas=$rep"; fi
        printf '%-10s %-12s %-34s %s\n' "$ns" "$(res_of "$kind")" "$name" "$s"
      done
    done
    show_nodes ;;
  *) echo "usage: $0 pause | pause-models | resume | status | is-paused" >&2; exit 64 ;;
esac
