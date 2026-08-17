#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_env.sh"

ENVIRONMENT="${1:?usage: verify_release.sh <staging|production> <version>}"
VERSION="${2:?usage: verify_release.sh <staging|production> <version>}"

load_opsforge_secrets
configure_opsforge_environment "$ENVIRONMENT"
export RELEASE_VERSION="$VERSION"

BASE_URL="http://127.0.0.1:$NGINX_HTTP_HOST_PORT"
CUSTOMER_ID="verify-$ENVIRONMENT-$VERSION"
REQUEST_ID=""
TICKET_ID=""

show_failure_evidence() {
  echo "OPSFORGE release verification FAILED: environment=$ENVIRONMENT version=$VERSION" >&2
  opsforge_compose ps >&2 || true
  opsforge_compose logs --no-color --tail=120 nginx api worker synthetic rabbitmq postgres-exporter redis-exporter prometheus grafana alloy loki tempo >&2 || true
}
trap show_failure_evidence ERR

wait_for_readiness() {
  for attempt in $(seq 1 45); do
    if curl -fsS "$BASE_URL/health/ready" > /tmp/opsforge-readiness.json; then
      if grep -q '"postgresql":"healthy"' /tmp/opsforge-readiness.json && \
         grep -q '"redis":"healthy"' /tmp/opsforge-readiness.json && \
         grep -q '"rabbitmq":"healthy"' /tmp/opsforge-readiness.json; then
        cat /tmp/opsforge-readiness.json
        return 0
      fi
    fi
    echo "Waiting for $ENVIRONMENT readiness: attempt $attempt/45"
    sleep 2
  done
  return 1
}

validate_version() {
  curl -fsS "$BASE_URL/version" > /tmp/opsforge-version.json
  cat /tmp/opsforge-version.json
  EXPECTED_ENVIRONMENT="$ENVIRONMENT" EXPECTED_VERSION="$VERSION" python - <<'PY'
import json
import os

with open('/tmp/opsforge-version.json', encoding='utf-8') as handle:
    payload = json.load(handle)

if payload.get('environment') != os.environ['EXPECTED_ENVIRONMENT']:
    raise SystemExit(f"environment mismatch: {payload}")
if payload.get('version') != os.environ['EXPECTED_VERSION']:
    raise SystemExit(f"version mismatch: {payload}")
PY
}

validate_schema_contract() {
  opsforge_compose exec -T db sh -lc \
    'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
    < "$ROOT/db/schema-contract.sql"
}

validate_browser_contract() {
  curl -fsS -i -X OPTIONS \
    -H 'Origin: http://localhost:3001' \
    -H 'Access-Control-Request-Method: PATCH' \
    -H 'Access-Control-Request-Headers: Content-Type, X-Customer-ID' \
    "$BASE_URL/api/tickets/1" > /tmp/opsforge-preflight.txt

  grep -qi '^Access-Control-Allow-Origin: http://localhost:3001' /tmp/opsforge-preflight.txt
  grep -qi '^Access-Control-Allow-Methods: GET, POST, PATCH, OPTIONS' /tmp/opsforge-preflight.txt
  grep -qi '^Access-Control-Allow-Headers: Authorization, Content-Type, X-Customer-ID' /tmp/opsforge-preflight.txt
}

validate_customer_journey() {
  curl -fsS \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "X-Customer-ID: $CUSTOMER_ID" \
    -D /tmp/opsforge-create-headers.txt \
    -d "{\"title\":\"Release verification $ENVIRONMENT $VERSION\",\"severity\":\"SEV3\"}" \
    "$BASE_URL/api/tickets" \
    -o /tmp/opsforge-create.json

  REQUEST_ID=$(awk 'BEGIN{IGNORECASE=1} /^X-Request-ID:/ {gsub("\r", "", $2); print $2}' /tmp/opsforge-create-headers.txt)
  TICKET_ID=$(python -c 'import json; print(json.load(open("/tmp/opsforge-create.json"))["id"])')
  test -n "$REQUEST_ID"
  test -n "$TICKET_ID"

  echo "Release verification request ID: $REQUEST_ID"
  echo "Release verification ticket ID: $TICKET_ID"

  for attempt in $(seq 1 30); do
    curl -fsS \
      -H "X-Customer-ID: $CUSTOMER_ID" \
      "$BASE_URL/api/tickets/$TICKET_ID" > /tmp/opsforge-ticket.json

    if python - <<'PY'
import json
with open('/tmp/opsforge-ticket.json', encoding='utf-8') as handle:
    state = json.load(handle)
processed = state.get('processing_status') == 'processed'
event = any(item.get('event_type') == 'ticket.processed' for item in state.get('events', []))
raise SystemExit(0 if processed and event else 1)
PY
    then
      break
    fi

    if [[ "$attempt" -eq 30 ]]; then
      return 1
    fi
    sleep 1
  done

  curl -fsS \
    -X PATCH \
    -H 'Content-Type: application/json' \
    -H "X-Customer-ID: $CUSTOMER_ID" \
    -d '{"status":"Resolved"}' \
    "$BASE_URL/api/tickets/$TICKET_ID" \
    -o /tmp/opsforge-update.json

  curl -fsS \
    -H "X-Customer-ID: $CUSTOMER_ID" \
    "$BASE_URL/api/tickets/$TICKET_ID" > /tmp/opsforge-final.json

  python - <<'PY'
import json
with open('/tmp/opsforge-final.json', encoding='utf-8') as handle:
    state = json.load(handle)
updated = any(
    item.get('event_type') == 'ticket.status_updated'
    and item.get('details', {}).get('status') == 'Resolved'
    for item in state.get('events', [])
)
raise SystemExit(0 if state.get('status') == 'Resolved' and updated else 1)
PY
}

validate_log_correlation() {
  for attempt in $(seq 1 12); do
    if opsforge_compose logs --no-color nginx 2>&1 | grep -F "$REQUEST_ID" >/dev/null && \
       opsforge_compose logs --no-color api 2>&1 | grep -F "$REQUEST_ID" >/dev/null && \
       opsforge_compose logs --no-color worker 2>&1 | grep -F "$REQUEST_ID" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

validate_loki_correlation() {
  local query result
  query="{service_name=~\".*(api|worker|nginx).*\"} |= \"$REQUEST_ID\""

  for attempt in $(seq 1 20); do
    result=$(curl -fsS -G "http://127.0.0.1:$LOKI_HOST_PORT/loki/api/v1/query_range" \
      --data-urlencode "query=$query" \
      --data-urlencode 'limit=20' \
      --data-urlencode 'since=10m' || true)
    if LOKI_JSON="$result" python - <<'PY'
import json
import os

try:
    payload = json.loads(os.environ['LOKI_JSON'])
except json.JSONDecodeError:
    raise SystemExit(1)
result = payload.get('data', {}).get('result', [])
raise SystemExit(0 if result else 1)
PY
    then
      echo "Loki contains centralized logs for request ID $REQUEST_ID"
      return 0
    fi
    sleep 2
  done
  return 1
}

validate_trace_correlation() {
  local query trace_result
  query="{ span.\"nightwatch.request_id\" = \"$REQUEST_ID\" }"

  for attempt in $(seq 1 20); do
    trace_result=$(curl -fsS -G "http://127.0.0.1:$TEMPO_HTTP_HOST_PORT/api/search" \
      --data-urlencode "q=$query" || true)
    if echo "$trace_result" | grep -q '"traceID"'; then
      echo "$trace_result"
      return 0
    fi
    sleep 2
  done
  return 1
}

validate_worker_and_queue() {
  local worker_id
  worker_id=$(opsforge_compose ps -q worker)
  test -n "$worker_id"
  test "$(docker inspect -f '{{.State.Health.Status}}' "$worker_id")" = "healthy"
  opsforge_compose exec -T rabbitmq rabbitmqctl list_queues name consumers | \
    awk '$1=="nightwatch-jobs" && $2>=1 {found=1} END {exit !found}'
}

prometheus_query_has_result() {
  local query="$1"
  local payload
  payload=$(curl -fsS -G "http://127.0.0.1:$PROMETHEUS_HOST_PORT/api/v1/query" \
    --data-urlencode "query=$query" || true)
  PROM_QUERY_JSON="$payload" python - <<'PY'
import json
import os

try:
    payload = json.loads(os.environ['PROM_QUERY_JSON'])
except json.JSONDecodeError:
    raise SystemExit(1)
result = payload.get('data', {}).get('result', [])
raise SystemExit(0 if result else 1)
PY
}

validate_business_telemetry() {
  local synthetic_query app_query

  for attempt in $(seq 1 20); do
    synthetic_query=$(curl -fsS -G "http://127.0.0.1:$PROMETHEUS_HOST_PORT/api/v1/query" \
      --data-urlencode 'query=nightwatch_synthetic_customer_path_up' || true)
    app_query=$(curl -fsS -G "http://127.0.0.1:$PROMETHEUS_HOST_PORT/api/v1/query" \
      --data-urlencode "query=nightwatch_app_info{environment=\"$ENVIRONMENT\",version=\"$VERSION\"}" || true)

    if SYNTHETIC_JSON="$synthetic_query" APP_JSON="$app_query" python - <<'PY'
import json
import os

synthetic = json.loads(os.environ['SYNTHETIC_JSON'])
app = json.loads(os.environ['APP_JSON'])
synthetic_result = synthetic.get('data', {}).get('result', [])
app_result = app.get('data', {}).get('result', [])
ok = synthetic_result and float(synthetic_result[0]['value'][1]) == 1.0 and app_result
raise SystemExit(0 if ok else 1)
PY
    then
      return 0
    fi
    sleep 2
  done
  return 1
}

validate_observability_targets() {
  local queries=(
    'up{job="nightwatch-postgres"} == 1'
    'up{job="nightwatch-redis"} == 1'
    'up{job="nightwatch-rabbitmq"} == 1'
    'pg_up == 1'
    'redis_up == 1'
    'pg_stat_activity_count{datname="nightwatch"}'
    'rabbitmq_queue_messages_ready{queue="nightwatch-jobs"}'
  )

  for attempt in $(seq 1 30); do
    local all_present=1
    for query in "${queries[@]}"; do
      if ! prometheus_query_has_result "$query"; then
        all_present=0
        break
      fi
    done
    if [[ "$all_present" -eq 1 ]]; then
      echo "Prometheus dependency and queue telemetry targets are queryable"
      return 0
    fi
    sleep 2
  done
  return 1
}

validate_prometheus_rules() {
  local rules_json
  for attempt in $(seq 1 20); do
    rules_json=$(curl -fsS "http://127.0.0.1:$PROMETHEUS_HOST_PORT/api/v1/rules" || true)
    if RULES_JSON="$rules_json" python - <<'PY'
import json
import os

try:
    payload = json.loads(os.environ['RULES_JSON'])
except json.JSONDecodeError:
    raise SystemExit(1)
groups = payload.get('data', {}).get('groups', [])
wanted = {'opsforge-recording', 'opsforge-detection'}
found = {group.get('name') for group in groups}
if not wanted.issubset(found):
    raise SystemExit(1)
for group in groups:
    if group.get('name') not in wanted:
        continue
    for rule in group.get('rules', []):
        if rule.get('health') not in (None, 'ok'):
            raise SystemExit(1)
raise SystemExit(0)
PY
    then
      if prometheus_query_has_result 'opsforge:postgres_connections' && \
         prometheus_query_has_result 'opsforge:rabbitmq_consumers'; then
        echo "OPSFORGE recording and detection rules are loaded and evaluating"
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

validate_grafana() {
  for attempt in $(seq 1 20); do
    if curl -fsS "http://127.0.0.1:$GRAFANA_HOST_PORT/api/health" >/dev/null; then
      curl -fsS -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
        "http://127.0.0.1:$GRAFANA_HOST_PORT/api/datasources/uid/prometheus" | grep '"uid":"prometheus"' >/dev/null
      curl -fsS -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
        "http://127.0.0.1:$GRAFANA_HOST_PORT/api/datasources/uid/loki" | grep '"uid":"loki"' >/dev/null
      curl -fsS -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
        "http://127.0.0.1:$GRAFANA_HOST_PORT/api/datasources/uid/tempo" | grep '"uid":"tempo"' >/dev/null
      if curl -fsS -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
        "http://127.0.0.1:$GRAFANA_HOST_PORT/api/dashboards/uid/opsforge-l2-operations" | \
        grep '"title":"OPSFORGE L2 Operations"' >/dev/null; then
        echo "Grafana datasources and OPSFORGE L2 Operations dashboard are provisioned"
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

wait_for_readiness
validate_version
validate_schema_contract
validate_browser_contract
validate_customer_journey
validate_log_correlation
validate_loki_correlation
validate_trace_correlation
validate_worker_and_queue
validate_business_telemetry
validate_observability_targets
validate_prometheus_rules
validate_grafana

trap - ERR
printf '%s\n' "OPSFORGE release verification PASSED: environment=$ENVIRONMENT version=$VERSION"
