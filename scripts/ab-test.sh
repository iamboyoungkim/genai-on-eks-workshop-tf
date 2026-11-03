#!/usr/bin/env bash
# A3 model-routing lab: send N requests to the `loan-processing` model group through the LiteLLM port-forward
# (127.0.0.1:4000, see `make pf-start`) and count which backend served each one.
#   eval "$(scripts/workshop.sh env)" is not needed; the key is read from the workshop .env (AGENT_KEY).
# Usage: scripts/ab-test.sh [N=100] [MODEL=loan-processing]   (also: loan-processing-simple / -complex)
set -euo pipefail
N="${1:-100}"
MODEL="${2:-loan-processing}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.workshop/starter-kit/.env"
[ -f "$ENV_FILE" ] || { echo "run scripts/workshop.sh setup first" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${AGENT_KEY:?AGENT_KEY missing; run scripts/workshop.sh agent-key (the key needs the loan-processing model)}"

curl -s -m 5 -o /dev/null http://127.0.0.1:4000/health/readiness || { echo "LiteLLM not reachable on 127.0.0.1:4000; run: make pf-start" >&2; exit 1; }

# x-litellm-model-id identifies the deployment that answered (Claude vs Qwen). The response body's `model`
# field is not reliable for that.
for i in $(seq 1 "$N"); do
  curl -s -m 120 -D - -o /dev/null -X POST http://127.0.0.1:4000/v1/chat/completions \
    -H "Content-Type: application/json" -H "Authorization: Bearer $AGENT_KEY" \
    -d "{\"model\":\"$MODEL\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"Evaluate loan application: Test User $i, income 75000, credit 720\"}]}" \
    | tr -d '\r' | awk -v IGNORECASE=1 'tolower($1)=="x-litellm-model-id:"{print substr($2,1,8)} /^HTTP/{s=$2} END{if(s!="200")print "HTTP " s}'
done | sort | uniq -c | sort -rn
echo "(model ids: see 'GET /model/info' - the larger weight is Claude, the smaller is Qwen)"
