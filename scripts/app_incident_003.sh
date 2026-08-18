#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_env.sh"

RELEASE="${1:?usage: app_incident_003.sh <release>}"
EVIDENCE_DIR="${APP003_EVIDENCE_DIR:-$ROOT/.opsforge/evidence/app-003}"
CUSTOMER_ID="app003-customer"
OVERRIDE_FILE="$EVIDENCE_DIR/app003.override.yml"
API_CONTAINER="nightwatch-staging-api"

load_opsforge_secrets
configure_opsforge_environment staging
export RELEASE_VERSION="$RELEASE"
BASE_URL="http://127.0.0.1:$NGINX_HTTP_HOST_PORT"
mkdir -p "$EVIDENCE_DIR"

app003_compose() {
  docker compose \
    -p "$OPSFORGE_PROJECT_NAME" \
    -f "$ROOT/docker-compose.yml" \
    -f "$OVERRIDE_FILE" \
    "$@"
}

write_override() {
  local value="$1"
  cat > "$OVERRIDE_FILE" <<EOF
services:
  api:
    environment:
      APP003_TICKET_EVENT_LIMIT: "$value"
EOF
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

recreate_api_with_config() {
  local value="$1"
  write_override "$value"
  app003_compose up -d --no-build --no-deps --force-recreate api

  for attempt in $(seq 1 60); do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$API_CONTAINER" 2>/dev/null || true)
    if [[ "$status" = "healthy" ]]; then
      break
    fi
    sleep 1
  done
  [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$API_CONTAINER")" = "healthy" ]]

  # Nginx resolves the Compose service name when its configuration is loaded.
  # Reloading does not change proxy configuration; it refreshes the upstream
  # address after the API container is recreated with new runtime environment.
  opsforge_compose exec -T nginx nginx -s reload
  wait_ready
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

echo "APP-003: deploying configuration-aware exercise release $RELEASE"
bash "$ROOT/scripts/deploy_release.sh" staging "$RELEASE"
wait_ready
curl -fsS "$BASE_URL/version" > "$EVIDENCE_DIR/version-before.json"
grep -q "\"version\":\"$RELEASE\"" "$EVIDENCE_DIR/version-before.json"
BASE_IMAGE_ID=$(docker inspect -f '{{.Image}}' "$API_CONTAINER")
printf '%s\n' "$BASE_IMAGE_ID" > "$EVIDENCE_DIR/api-image-before.txt"

create_code=$(curl -sS -o "$EVIDENCE_DIR/create.json" -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -H "X-Customer-ID: $CUSTOMER_ID" \
  -d '{"title":"APP-003 malformed configuration probe","severity":"SEV2"}' \
  "$BASE_URL/api/tickets")
[[ "$create_code" = "201" ]]
TICKET_ID=$(python -c 'import json; print(json.load(open("'"$EVIDENCE_DIR"'/create.json"))["id"])')

baseline_code=$(curl -sS -o "$EVIDENCE_DIR/baseline-ticket.json" -w '%{http_code}' \
  -H "X-Customer-ID: $CUSTOMER_ID" "$BASE_URL/api/tickets/$TICKET_ID")
[[ "$baseline_code" = "200" ]]

echo "APP-003: injecting malformed runtime configuration"
recreate_api_with_config "not-a-number"
MISCONFIGURED_IMAGE_ID=$(docker inspect -f '{{.Image}}' "$API_CONTAINER")
[[ "$MISCONFIGURED_IMAGE_ID" = "$BASE_IMAGE_ID" ]]
printf '%s\n' "$MISCONFIGURED_IMAGE_ID" > "$EVIDENCE_DIR/api-image-misconfigured.txt"

docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$API_CONTAINER" > "$EVIDENCE_DIR/api-environment.txt"
grep -q '^APP003_TICKET_EVENT_LIMIT=not-a-number$' "$EVIDENCE_DIR/api-environment.txt"
curl -fsS "$BASE_URL/version" > "$EVIDENCE_DIR/version-misconfigured.json"
grep -q "\"version\":\"$RELEASE\"" "$EVIDENCE_DIR/version-misconfigured.json"

for endpoint in db-health cache-health queue-health; do
  code=$(curl -sS -o "$EVIDENCE_DIR/$endpoint.json" -w '%{http_code}' "$BASE_URL/$endpoint")
  [[ "$code" = "200" ]]
done

read_result=$(curl -sS -D "$EVIDENCE_DIR/failure-headers.txt" -o "$EVIDENCE_DIR/failure-body.json" \
  -w '%{http_code}|%{time_total}' -H "X-Customer-ID: $CUSTOMER_ID" "$BASE_URL/api/tickets/$TICKET_ID")
IFS='|' read -r READ_CODE READ_SECONDS <<< "$read_result"
[[ "$READ_CODE" = "500" ]]
REQUEST_ID=$(awk 'BEGIN{IGNORECASE=1} /^X-Request-ID:/ {gsub("\r", "", $2); print $2}' "$EVIDENCE_DIR/failure-headers.txt")
test -n "$REQUEST_ID"
grep -q 'application configuration invalid' "$EVIDENCE_DIR/failure-body.json"
grep -q 'APP003_TICKET_EVENT_LIMIT' "$EVIDENCE_DIR/failure-body.json"

opsforge_compose logs --no-color --tail=260 nginx > "$EVIDENCE_DIR/nginx.log" 2>&1
opsforge_compose logs --no-color --tail=260 api > "$EVIDENCE_DIR/api.log" 2>&1
grep -F "$REQUEST_ID" "$EVIDENCE_DIR/nginx.log" >/dev/null
grep -F "$REQUEST_ID" "$EVIDENCE_DIR/api.log" >/dev/null
grep -F '"event":"configuration_error"' "$EVIDENCE_DIR/api.log" >/dev/null
grep -F '"config_key":"APP003_TICKET_EVENT_LIMIT"' "$EVIDENCE_DIR/api.log" >/dev/null
grep -F '"supplied_value":"not-a-number"' "$EVIDENCE_DIR/api.log" >/dev/null
wait_tempo "$REQUEST_ID"
wait_loki "$REQUEST_ID"

cat > "$EVIDENCE_DIR/diagnosis.txt" <<EOF
customer_read_http=500
customer_read_seconds=$READ_SECONDS
request_id=$REQUEST_ID
ticket_id=$TICKET_ID
release=$RELEASE
api_image_id=$BASE_IMAGE_ID
api_image_unchanged_after_config_change=true
postgresql=healthy
redis=healthy
rabbitmq=healthy
malformed_config_key=APP003_TICKET_EVENT_LIMIT
malformed_config_value=not-a-number
expected_config=integer_1_to_200
nginx_request_correlated=true
api_request_correlated=true
configuration_error_log=true
tempo_correlated=true
loki_correlated=true
assessment=runtime application configuration is malformed while release image and core dependencies remain healthy
EOF

echo "APP-003 diagnosis proven: runtime configuration is malformed; image and core dependencies are healthy."

echo "APP-003: correcting runtime configuration without changing the release image"
recreate_api_with_config "25"
RECOVERED_IMAGE_ID=$(docker inspect -f '{{.Image}}' "$API_CONTAINER")
[[ "$RECOVERED_IMAGE_ID" = "$BASE_IMAGE_ID" ]]
printf '%s\n' "$RECOVERED_IMAGE_ID" > "$EVIDENCE_DIR/api-image-recovered.txt"

docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$API_CONTAINER" > "$EVIDENCE_DIR/api-environment-recovered.txt"
grep -q '^APP003_TICKET_EVENT_LIMIT=25$' "$EVIDENCE_DIR/api-environment-recovered.txt"
curl -fsS "$BASE_URL/version" > "$EVIDENCE_DIR/version-recovered.json"
grep -q "\"version\":\"$RELEASE\"" "$EVIDENCE_DIR/version-recovered.json"

recovery_code=$(curl -sS -o "$EVIDENCE_DIR/recovered-ticket.json" -w '%{http_code}' \
  -H "X-Customer-ID: $CUSTOMER_ID" "$BASE_URL/api/tickets/$TICKET_ID")
[[ "$recovery_code" = "200" ]]
wait_ready
bash "$ROOT/scripts/verify_release.sh" staging "$RELEASE"

cat > "$EVIDENCE_DIR/recovery.txt" <<EOF
recovered_release=$RELEASE
recovered_api_image_id=$RECOVERED_IMAGE_ID
api_image_unchanged=true
corrected_config_key=APP003_TICKET_EVENT_LIMIT
corrected_config_value=25
application_code_rollback_required=false
original_ticket_http=200
full_customer_journey_verified=true
EOF

echo "APP-003 recovery verified: corrected runtime configuration restores the customer path on the same image."
