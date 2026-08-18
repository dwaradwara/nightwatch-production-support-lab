#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_env.sh"

RELEASE="${1:?usage: app_incident_002.sh <release>}"
EVIDENCE_DIR="${APP002_EVIDENCE_DIR:-$ROOT/.opsforge/evidence/app-002}"
CUSTOMER_ID="app002-customer"
DEPENDENCY_CONTAINER="opsforge-app002-dependency"

load_opsforge_secrets
configure_opsforge_environment staging
BASE_URL="http://127.0.0.1:$NGINX_HTTP_HOST_PORT"
mkdir -p "$EVIDENCE_DIR"

cleanup_dependency() {
  docker rm -f "$DEPENDENCY_CONTAINER" >/dev/null 2>&1 || true
}

start_dependency() {
  local delay_seconds="$1"
  cleanup_dependency
  docker run -d --name "$DEPENDENCY_CONTAINER" \
    --network "$OPSFORGE_NETWORK_NAME" \
    --network-alias app002-slow \
    -e "APP002_DELAY_SECONDS=$delay_seconds" \
    "nightwatch-api:$RELEASE" \
    python -u -c '
import os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

delay=float(os.environ.get("APP002_DELAY_SECONDS", "0"))
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(delay)
        body=b"{\"status\":\"ok\"}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass
    def log_message(self, fmt, *args):
        pass
ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
' >/dev/null
}

wait_ready() {
  for attempt in $(seq 1 60); do
    code=$(curl -sS -o "$EVIDENCE_DIR/readiness.json" -w '%{http_code}' "$BASE_URL/health/ready" 2>/dev/null || true)
    if [[ "$code" = "200" ]] && \
       grep -q '"postgresql":"healthy"' "$EVIDENCE_DIR/readiness.json" && \
       grep -q '"redis":"healthy"' "$EVIDENCE_DIR/readiness.json" && \
       grep -q '"rabbitmq":"healthy"' "$EVIDENCE_DIR/readiness.json"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

probe_dependency() {
  local output_file="$1"
  opsforge_compose exec -T api python - <<'PY' > "$output_file"
import time, urllib.request
started=time.perf_counter()
with urllib.request.urlopen("http://app002-slow:8080/policy", timeout=6) as response:
    response.read()
elapsed=time.perf_counter()-started
print(f"status={response.status}")
print(f"elapsed_seconds={elapsed:.3f}")
PY
}

wait_tempo() {
  local request_id="$1" result query
  query="{ span.\"nightwatch.request_id\" = \"$request_id\" }"
  for attempt in $(seq 1 20); do
    result=$(curl -fsS -G "http://127.0.0.1:$TEMPO_HTTP_HOST_PORT/api/search" --data-urlencode "q=$query" || true)
    printf '%s\n' "$result" > "$EVIDENCE_DIR/tempo-search.json"
    if grep -q '"traceID"' "$EVIDENCE_DIR/tempo-search.json"; then return 0; fi
    sleep 2
  done
  return 1
}

wait_loki() {
  local request_id="$1" result query
  query="{service_name=~\".*(api|nginx).*\"} |= \"$request_id\""
  for attempt in $(seq 1 20); do
    result=$(curl -fsS -G "http://127.0.0.1:$LOKI_HOST_PORT/loki/api/v1/query_range" \
      --data-urlencode "query=$query" --data-urlencode 'limit=20' --data-urlencode 'since=10m' || true)
    printf '%s\n' "$result" > "$EVIDENCE_DIR/loki-query.json"
    if LOKI_JSON="$result" python - <<'PY'
import json, os
try:
    payload=json.loads(os.environ['LOKI_JSON'])
except json.JSONDecodeError:
    raise SystemExit(1)
raise SystemExit(0 if payload.get('data', {}).get('result') else 1)
PY
    then return 0; fi
    sleep 2
  done
  return 1
}

echo "APP-002: deploying dependency-timeout exercise release $RELEASE"
bash "$ROOT/scripts/deploy_release.sh" staging "$RELEASE"
wait_ready
curl -fsS "$BASE_URL/version" > "$EVIDENCE_DIR/version.json"
grep -q "\"version\":\"$RELEASE\"" "$EVIDENCE_DIR/version.json"

for endpoint in db-health cache-health queue-health; do
  code=$(curl -sS -o "$EVIDENCE_DIR/$endpoint.json" -w '%{http_code}' "$BASE_URL/$endpoint")
  [[ "$code" = "200" ]]
done

start_dependency 3.0
sleep 1
probe_dependency "$EVIDENCE_DIR/slow-dependency-probe.txt"
grep -q '^status=200$' "$EVIDENCE_DIR/slow-dependency-probe.txt"
python - "$EVIDENCE_DIR/slow-dependency-probe.txt" <<'PY'
import sys
values=dict(line.strip().split('=',1) for line in open(sys.argv[1]) if '=' in line)
elapsed=float(values['elapsed_seconds'])
assert elapsed >= 2.5, elapsed
PY

create_code=$(curl -sS -o "$EVIDENCE_DIR/create.json" -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -H "X-Customer-ID: $CUSTOMER_ID" \
  -d '{"title":"APP-002 dependency timeout probe","severity":"SEV2"}' \
  "$BASE_URL/api/tickets")
[[ "$create_code" = "201" ]]
TICKET_ID=$(python -c 'import json; print(json.load(open("'"$EVIDENCE_DIR"'/create.json"))["id"])')

read_result=$(curl -sS -D "$EVIDENCE_DIR/timeout-headers.txt" -o "$EVIDENCE_DIR/timeout-body.json" \
  -w '%{http_code}|%{time_total}' -H "X-Customer-ID: $CUSTOMER_ID" "$BASE_URL/api/tickets/$TICKET_ID")
IFS='|' read -r READ_CODE READ_SECONDS <<< "$read_result"
[[ "$READ_CODE" = "504" ]]
python - <<PY
elapsed=float('$READ_SECONDS')
assert 0.8 <= elapsed <= 2.5, elapsed
PY
REQUEST_ID=$(awk 'BEGIN{IGNORECASE=1} /^X-Request-ID:/ {gsub("\r", "", $2); print $2}' "$EVIDENCE_DIR/timeout-headers.txt")
test -n "$REQUEST_ID"
grep -q 'downstream dependency timed out' "$EVIDENCE_DIR/timeout-body.json"

opsforge_compose logs --no-color --tail=260 nginx > "$EVIDENCE_DIR/nginx.log" 2>&1
opsforge_compose logs --no-color --tail=260 api > "$EVIDENCE_DIR/api.log" 2>&1
grep -F "$REQUEST_ID" "$EVIDENCE_DIR/nginx.log" >/dev/null
grep -F "$REQUEST_ID" "$EVIDENCE_DIR/api.log" >/dev/null
grep -F '"event":"dependency_timeout"' "$EVIDENCE_DIR/api.log" >/dev/null
grep -F '"dependency":"app002-policy-service"' "$EVIDENCE_DIR/api.log" >/dev/null
wait_tempo "$REQUEST_ID"
wait_loki "$REQUEST_ID"

cat > "$EVIDENCE_DIR/diagnosis.txt" <<EOF
customer_read_http=504
customer_read_seconds=$READ_SECONDS
request_id=$REQUEST_ID
ticket_id=$TICKET_ID
release=$RELEASE
postgresql=healthy
redis=healthy
rabbitmq=healthy
dependency_direct_http=200
dependency_direct_latency_seconds=$(awk -F= '/elapsed_seconds/{print $2}' "$EVIDENCE_DIR/slow-dependency-probe.txt")
api_dependency_timeout_seconds=1.0
nginx_request_correlated=true
api_request_correlated=true
dependency_timeout_log=true
tempo_correlated=true
loki_correlated=true
assessment=reachable downstream dependency exceeds application timeout budget
EOF

echo "APP-002 diagnosis proven: downstream is reachable but slower than the API timeout budget."

start_dependency 0.05
sleep 1
probe_dependency "$EVIDENCE_DIR/recovered-dependency-probe.txt"
grep -q '^status=200$' "$EVIDENCE_DIR/recovered-dependency-probe.txt"
python - "$EVIDENCE_DIR/recovered-dependency-probe.txt" <<'PY'
import sys
values=dict(line.strip().split('=',1) for line in open(sys.argv[1]) if '=' in line)
elapsed=float(values['elapsed_seconds'])
assert elapsed < 1.0, elapsed
PY

recovery_code=$(curl -sS -o "$EVIDENCE_DIR/recovered-ticket.json" -w '%{http_code}' \
  -H "X-Customer-ID: $CUSTOMER_ID" "$BASE_URL/api/tickets/$TICKET_ID")
[[ "$recovery_code" = "200" ]]
wait_ready
bash "$ROOT/scripts/verify_release.sh" staging "$RELEASE"

cat > "$EVIDENCE_DIR/recovery.txt" <<EOF
recovered_release=$RELEASE
api_redeploy_required=false
dependency_recovery_latency_seconds=$(awk -F= '/elapsed_seconds/{print $2}' "$EVIDENCE_DIR/recovered-dependency-probe.txt")
original_ticket_http=200
full_customer_journey_verified=true
EOF

echo "APP-002 recovery verified: same API release succeeds after dependency latency normalizes."
