#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_env.sh"

GOOD_RELEASE="${1:?usage: app_incident_001.sh <good-release> <bad-release>}"
BAD_RELEASE="${2:?usage: app_incident_001.sh <good-release> <bad-release>}"
EVIDENCE_DIR="${APP001_EVIDENCE_DIR:-$ROOT/.opsforge/evidence/app-001}"
CUSTOMER_ID="app001-customer"

load_opsforge_secrets
configure_opsforge_environment staging
BASE_URL="http://127.0.0.1:$NGINX_HTTP_HOST_PORT"
mkdir -p "$EVIDENCE_DIR"

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

wait_tempo() {
  local request_id="$1" result query
  query="{ span.\"nightwatch.request_id\" = \"$request_id\" }"
  for attempt in $(seq 1 20); do
    result=$(curl -fsS -G "http://127.0.0.1:$TEMPO_HTTP_HOST_PORT/api/search" --data-urlencode "q=$query" || true)
    printf '%s\n' "$result" > "$EVIDENCE_DIR/tempo-search.json"
    if grep -q '"traceID"' "$EVIDENCE_DIR/tempo-search.json"; then
      return 0
    fi
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
    then
      return 0
    fi
    sleep 2
  done
  return 1
}

echo "APP-001: deploying controlled application-regression release $BAD_RELEASE"
bash "$ROOT/scripts/deploy_release.sh" staging "$BAD_RELEASE"
wait_ready

curl -fsS "$BASE_URL/version" > "$EVIDENCE_DIR/bad-version.json"
grep -q "\"version\":\"$BAD_RELEASE\"" "$EVIDENCE_DIR/bad-version.json"

for endpoint in db-health cache-health queue-health; do
  code=$(curl -sS -o "$EVIDENCE_DIR/$endpoint.json" -w '%{http_code}' "$BASE_URL/$endpoint")
  [[ "$code" = "200" ]]
done

create_code=$(curl -sS -D "$EVIDENCE_DIR/create-headers.txt" -o "$EVIDENCE_DIR/create.json" -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -H "X-Customer-ID: $CUSTOMER_ID" \
  -d '{"title":"APP-001 release regression probe","severity":"SEV2"}' \
  "$BASE_URL/api/tickets")
[[ "$create_code" = "201" ]]
TICKET_ID=$(python -c 'import json; print(json.load(open("'"$EVIDENCE_DIR"'/create.json"))["id"])')

read_code=$(curl -sS -D "$EVIDENCE_DIR/failing-read-headers.txt" -o "$EVIDENCE_DIR/failing-read-body.txt" -w '%{http_code}' \
  -H "X-Customer-ID: $CUSTOMER_ID" "$BASE_URL/api/tickets/$TICKET_ID")
[[ "$read_code" = "500" ]]
REQUEST_ID=$(awk 'BEGIN{IGNORECASE=1} /^X-Request-ID:/ {gsub("\r", "", $2); print $2}' "$EVIDENCE_DIR/failing-read-headers.txt")
test -n "$REQUEST_ID"

opsforge_compose exec -T db sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -Atc "SELECT id || '\''|'\'' || customer_id || '\''|'\'' || status FROM tickets WHERE id='"$TICKET_ID"';"' \
  > "$EVIDENCE_DIR/database-ticket.txt"
grep -q "^$TICKET_ID|$CUSTOMER_ID|Open$" "$EVIDENCE_DIR/database-ticket.txt"

opsforge_compose logs --no-color --tail=240 nginx > "$EVIDENCE_DIR/nginx.log" 2>&1
opsforge_compose logs --no-color --tail=240 api > "$EVIDENCE_DIR/api.log" 2>&1
grep -F "$REQUEST_ID" "$EVIDENCE_DIR/nginx.log" >/dev/null
grep -F "$REQUEST_ID" "$EVIDENCE_DIR/api.log" >/dev/null
grep -F 'OPSFORGE simulated application ticket-read regression' "$EVIDENCE_DIR/api.log" >/dev/null

wait_tempo "$REQUEST_ID"
wait_loki "$REQUEST_ID"

cat > "$EVIDENCE_DIR/diagnosis.txt" <<EOF
customer_read_http=500
request_id=$REQUEST_ID
ticket_id=$TICKET_ID
bad_release=$BAD_RELEASE
postgresql=healthy
redis=healthy
rabbitmq=healthy
database_ticket_present=true
nginx_request_correlated=true
api_request_correlated=true
api_runtime_exception=true
tempo_correlated=true
loki_correlated=true
assessment=release-specific application failure in customer ticket-read handler
EOF

echo "APP-001 diagnosis proven: dependencies healthy, persisted ticket exists, and the same failing request reaches the API exception."

echo "APP-001: rolling staging back to known-good release $GOOD_RELEASE"
bash "$ROOT/scripts/deploy_release.sh" staging "$GOOD_RELEASE"
wait_ready

curl -fsS "$BASE_URL/version" > "$EVIDENCE_DIR/recovered-version.json"
grep -q "\"version\":\"$GOOD_RELEASE\"" "$EVIDENCE_DIR/recovered-version.json"
recovery_code=$(curl -sS -o "$EVIDENCE_DIR/recovered-ticket.json" -w '%{http_code}' \
  -H "X-Customer-ID: $CUSTOMER_ID" "$BASE_URL/api/tickets/$TICKET_ID")
[[ "$recovery_code" = "200" ]]
python - <<PY
import json
p=json.load(open('$EVIDENCE_DIR/recovered-ticket.json'))
assert p['id'] == int('$TICKET_ID')
assert p['customer_id'] == '$CUSTOMER_ID'
PY

bash "$ROOT/scripts/verify_release.sh" staging "$GOOD_RELEASE"

cat > "$EVIDENCE_DIR/recovery.txt" <<EOF
recovered_release=$GOOD_RELEASE
original_ticket_http=200
original_ticket_preserved=true
full_customer_journey_verified=true
EOF

echo "APP-001 recovery verified: known-good release restored the original customer read and the complete release verification passed."
