#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:?usage: qw_incident_001.sh <baseline|inject|diagnose|recover|verify|exercise>}"
PROJECT_NAME="${OPSFORGE_PROJECT_NAME:-opsforge-qw001}"
POSTGRES_USER="${POSTGRES_USER:-nightwatch}"
POSTGRES_DB="${POSTGRES_DB:-nightwatch}"
API_URL="${QW001_API_URL:-http://127.0.0.1:${API_HOST_PORT:-18101}}"
EVIDENCE_DIR="${QW001_EVIDENCE_DIR:-$ROOT/.opsforge/evidence/qw-001}"
QUEUE_NAME="${QW001_QUEUE_NAME:-nightwatch-jobs}"
BASELINE_CUSTOMER="opsforge-qw001-baseline"
INCIDENT_CUSTOMER="opsforge-qw001-incident"

mkdir -p "$EVIDENCE_DIR"

compose() {
  docker compose -p "$PROJECT_NAME" -f "$ROOT/docker-compose.yml" "$@"
}

psql_cmd() {
  compose exec -T db psql \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    -X \
    -v ON_ERROR_STOP=1 \
    "$@"
}

queue_state() {
  compose exec -T rabbitmq rabbitmqctl -q list_queues name messages_ready messages_unacknowledged consumers \
    | awk -v queue="$QUEUE_NAME" '$1 == queue {print $2, $3, $4}'
}

wait_for_api_ready() {
  for _ in {1..60}; do
    local status
    status=$(curl -sS -o /tmp/qw001-ready.json -w '%{http_code}' "$API_URL/health/ready" 2>/dev/null || true)
    if [[ "$status" = "200" ]]; then
      return 0
    fi
    sleep 1
  done
  compose ps -a
  compose logs --no-color api worker rabbitmq db redis || true
  echo "QW-001 API did not become ready" >&2
  return 1
}

wait_for_worker_healthy() {
  local container
  container="${OPSFORGE_CONTAINER_PREFIX:-nightwatch-qw001}-worker"
  for _ in {1..60}; do
    local status
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)
    if [[ "$status" = "healthy" ]]; then
      return 0
    fi
    sleep 1
  done
  compose ps -a worker
  compose logs --no-color worker || true
  echo "QW-001 worker did not become healthy" >&2
  return 1
}

wait_for_consumer_count() {
  local expected="$1"
  for _ in {1..40}; do
    local ready unacked consumers
    read -r ready unacked consumers <<<"$(queue_state || true)"
    if [[ -n "${consumers:-}" && "$consumers" = "$expected" ]]; then
      return 0
    fi
    sleep 0.5
  done
  queue_state || true
  echo "QW-001 expected RabbitMQ consumer count $expected" >&2
  return 1
}

create_ticket() {
  local customer="$1"
  local title="$2"
  local prefix="$3"
  local headers="$EVIDENCE_DIR/${prefix}-headers.txt"
  local body="$EVIDENCE_DIR/${prefix}-body.json"
  local status

  status=$(curl -sS -D "$headers" -o "$body" -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -H "X-Customer-ID: $customer" \
    -X POST "$API_URL/api/tickets" \
    -d "{\"title\":\"$title\",\"severity\":\"SEV3\"}")

  printf '%s\n' "$status" > "$EVIDENCE_DIR/${prefix}-http-status.txt"
  if [[ "$status" != "201" ]]; then
    cat "$body" >&2 || true
    echo "QW-001 ticket creation failed with HTTP $status" >&2
    return 1
  fi

  python3 - "$body" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
print(payload["id"])
PY
}

request_id_from_headers() {
  awk 'tolower($1) == "x-request-id:" {gsub("\\r", "", $2); print $2}' "$1" | tail -1
}

ticket_status() {
  local ticket_id="$1"
  psql_cmd -Atc "SELECT processing_status FROM tickets WHERE id = $ticket_id;"
}

wait_for_ticket_status() {
  local ticket_id="$1"
  local expected="$2"
  for _ in {1..60}; do
    local state
    state=$(ticket_status "$ticket_id" 2>/dev/null || true)
    if [[ "$state" = "$expected" ]]; then
      return 0
    fi
    sleep 0.5
  done
  echo "QW-001 ticket $ticket_id did not reach processing_status=$expected" >&2
  return 1
}

capture_queue_state() {
  local file="$1"
  local ready unacked consumers
  read -r ready unacked consumers <<<"$(queue_state)"
  printf 'messages_ready=%s\nmessages_unacknowledged=%s\nconsumers=%s\n' \
    "$ready" "$unacked" "$consumers" | tee "$file"
}

baseline() {
  wait_for_api_ready
  wait_for_worker_healthy
  wait_for_consumer_count 1

  local worker_container api_container baseline_ticket
  worker_container=$(compose ps -q worker)
  api_container=$(compose ps -q api)
  printf 'worker_container_id=%s\napi_container_id=%s\n' "$worker_container" "$api_container" \
    | tee "$EVIDENCE_DIR/baseline-runtime-identity.txt"

  capture_queue_state "$EVIDENCE_DIR/baseline-queue-state-before.txt"

  baseline_ticket=$(create_ticket "$BASELINE_CUSTOMER" "QW-001 healthy consumer baseline" "baseline-create")
  printf '%s\n' "$baseline_ticket" > "$EVIDENCE_DIR/baseline-ticket-id.txt"
  wait_for_ticket_status "$baseline_ticket" processed

  capture_queue_state "$EVIDENCE_DIR/baseline-queue-state-after.txt"
  if ! grep -qx 'messages_ready=0' "$EVIDENCE_DIR/baseline-queue-state-after.txt"; then
    echo "QW-001 baseline queue did not drain" >&2
    return 1
  fi
  if ! grep -qx 'consumers=1' "$EVIDENCE_DIR/baseline-queue-state-after.txt"; then
    echo "QW-001 baseline requires one worker consumer" >&2
    return 1
  fi

  echo "QW-001 baseline verified: worker consumer present and ticket processing completes."
}

inject() {
  compose stop worker >/dev/null
  wait_for_consumer_count 0
  compose ps -a worker | tee "$EVIDENCE_DIR/incident-worker-state.txt"
  capture_queue_state "$EVIDENCE_DIR/incident-queue-state-before-ticket.txt"
  echo "QW-001 fault injected: worker stopped while RabbitMQ and API dependencies remain running."
}

diagnose() {
  local ticket_id request_id ready_status queue_status db_ok redis_ok processing ready unacked consumers

  ticket_id=$(create_ticket "$INCIDENT_CUSTOMER" "QW-001 queued with no consumer" "incident-create")
  printf '%s\n' "$ticket_id" > "$EVIDENCE_DIR/incident-ticket-id.txt"
  request_id=$(request_id_from_headers "$EVIDENCE_DIR/incident-create-headers.txt")
  printf '%s\n' "$request_id" > "$EVIDENCE_DIR/incident-request-id.txt"

  processing=$(ticket_status "$ticket_id")
  printf '%s\n' "$processing" | tee "$EVIDENCE_DIR/incident-processing-status.txt"
  if [[ "$processing" != "queued" ]]; then
    echo "QW-001 expected target ticket to remain queued while consumer count is zero" >&2
    return 1
  fi

  ready_status=$(curl -sS -o "$EVIDENCE_DIR/incident-readiness.json" -w '%{http_code}' "$API_URL/health/ready")
  queue_status=$(curl -sS -o "$EVIDENCE_DIR/incident-queue-health.json" -w '%{http_code}' "$API_URL/queue-health")
  db_ok=$(psql_cmd -Atc 'SELECT 1;')
  redis_ok=$(compose exec -T redis redis-cli ping)
  printf 'readiness_http=%s\nqueue_health_http=%s\ndb_select_1=%s\nredis_ping=%s\n' \
    "$ready_status" "$queue_status" "$db_ok" "$redis_ok" \
    | tee "$EVIDENCE_DIR/incident-dependency-health.txt"

  if [[ "$ready_status" != "200" || "$queue_status" != "200" || "$db_ok" != "1" || "$redis_ok" != "PONG" ]]; then
    echo "QW-001 expected API, RabbitMQ, PostgreSQL, and Redis to remain healthy" >&2
    return 1
  fi

  capture_queue_state "$EVIDENCE_DIR/incident-queue-state.txt"
  read -r ready unacked consumers <<<"$(queue_state)"
  if (( ready < 1 )) || [[ "$unacked" != "0" || "$consumers" != "0" ]]; then
    echo "QW-001 expected ready backlog >=1, no unacked messages, and zero consumers" >&2
    return 1
  fi

  compose exec -T rabbitmq rabbitmq-diagnostics -q ping \
    | tee "$EVIDENCE_DIR/incident-rabbitmq-ping.txt"
  compose logs --no-color api > "$EVIDENCE_DIR/incident-api.log" 2>&1 || true
  compose logs --no-color worker > "$EVIDENCE_DIR/incident-worker-before-recovery.log" 2>&1 || true

  if [[ -z "$request_id" ]] || ! grep -q "$request_id" "$EVIDENCE_DIR/incident-api.log"; then
    echo "QW-001 API request correlation evidence is missing" >&2
    return 1
  fi
  if grep -q "$request_id" "$EVIDENCE_DIR/incident-worker-before-recovery.log"; then
    echo "QW-001 target request unexpectedly reached worker before recovery" >&2
    return 1
  fi

  psql_cmd -P pager=off -c "
    SELECT id, customer_id, processing_status, processed_at, request_id
    FROM tickets
    WHERE id = $ticket_id;
  " | tee "$EVIDENCE_DIR/incident-ticket-db-state.txt"

  echo "QW-001 diagnosis verified: broker and synchronous API are healthy, consumer count is zero, the durable message is ready, and the ticket remains queued."
}

recover() {
  local worker_before worker_after
  worker_before=$(awk -F= '/worker_container_id/ {print $2}' "$EVIDENCE_DIR/baseline-runtime-identity.txt")

  compose start worker >/dev/null
  wait_for_worker_healthy
  wait_for_consumer_count 1

  worker_after=$(compose ps -q worker)
  printf 'worker_container_before=%s\nworker_container_after=%s\n' "$worker_before" "$worker_after" \
    | tee "$EVIDENCE_DIR/recovery-runtime-identity.txt"
  if [[ "$worker_before" != "$worker_after" ]]; then
    echo "QW-001 expected worker-only start of the same container, not redeployment" >&2
    return 1
  fi

  local ticket_id
  ticket_id=$(cat "$EVIDENCE_DIR/incident-ticket-id.txt")
  wait_for_ticket_status "$ticket_id" processed
  echo "QW-001 targeted worker recovery executed and queued ticket reached processed state."
}

verify() {
  local ticket_id request_id customer_status processing ready unacked consumers api_before api_after
  ticket_id=$(cat "$EVIDENCE_DIR/incident-ticket-id.txt")
  request_id=$(cat "$EVIDENCE_DIR/incident-request-id.txt")

  customer_status=$(curl -sS -o "$EVIDENCE_DIR/post-recovery-ticket.json" -w '%{http_code}' \
    -H "X-Customer-ID: $INCIDENT_CUSTOMER" \
    "$API_URL/api/tickets/$ticket_id")
  printf '%s\n' "$customer_status" > "$EVIDENCE_DIR/post-recovery-ticket-http-status.txt"
  if [[ "$customer_status" != "200" ]]; then
    echo "QW-001 recovered customer ticket read failed" >&2
    return 1
  fi

  processing=$(ticket_status "$ticket_id")
  printf '%s\n' "$processing" | tee "$EVIDENCE_DIR/post-recovery-processing-status.txt"
  if [[ "$processing" != "processed" ]]; then
    echo "QW-001 target ticket did not finish processing after consumer recovery" >&2
    return 1
  fi

  capture_queue_state "$EVIDENCE_DIR/post-recovery-queue-state.txt"
  read -r ready unacked consumers <<<"$(queue_state)"
  if [[ "$ready" != "0" || "$unacked" != "0" || "$consumers" != "1" ]]; then
    echo "QW-001 queue did not return to empty/consumed state" >&2
    return 1
  fi

  compose logs --no-color worker > "$EVIDENCE_DIR/post-recovery-worker.log" 2>&1 || true
  if ! grep "$request_id" "$EVIDENCE_DIR/post-recovery-worker.log" | grep -q '"event":"job_completed"'; then
    echo "QW-001 worker recovery log does not contain correlated job completion" >&2
    return 1
  fi

  api_before=$(awk -F= '/api_container_id/ {print $2}' "$EVIDENCE_DIR/baseline-runtime-identity.txt")
  api_after=$(compose ps -q api)
  printf 'api_container_before=%s\napi_container_after=%s\n' "$api_before" "$api_after" \
    | tee "$EVIDENCE_DIR/post-recovery-api-identity.txt"
  if [[ "$api_before" != "$api_after" ]]; then
    echo "QW-001 API container changed during worker-only recovery" >&2
    return 1
  fi

  curl -sS "$API_URL/health/ready" | tee "$EVIDENCE_DIR/post-recovery-readiness.json" >/dev/null
  psql_cmd -Atc 'SELECT 1;' | tee "$EVIDENCE_DIR/post-recovery-db-health.txt"
  compose exec -T rabbitmq rabbitmq-diagnostics -q ping \
    | tee "$EVIDENCE_DIR/post-recovery-rabbitmq-ping.txt"

  echo "QW-001 recovery verified: consumer restored, backlog drained, correlated job completed, and API/database/broker remained unchanged and healthy."
}

exercise() {
  baseline
  inject
  diagnose
  recover
  verify
  echo "QW-001 exercise verified: missing consumer isolated from broker/API health and resolved with worker-only recovery."
}

case "$ACTION" in
  baseline) baseline ;;
  inject) inject ;;
  diagnose) diagnose ;;
  recover) recover ;;
  verify) verify ;;
  exercise) exercise ;;
  *)
    echo "Unsupported action: $ACTION" >&2
    exit 2
    ;;
esac
