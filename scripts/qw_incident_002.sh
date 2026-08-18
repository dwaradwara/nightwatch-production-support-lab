#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:?usage: qw_incident_002.sh <baseline|inject|diagnose|recover|verify|exercise>}"
PROJECT_NAME="${OPSFORGE_PROJECT_NAME:-opsforge-qw002}"
POSTGRES_USER="${POSTGRES_USER:-nightwatch}"
POSTGRES_DB="${POSTGRES_DB:-nightwatch}"
API_URL="${QW002_API_URL:-http://127.0.0.1:${API_HOST_PORT:-18102}}"
EVIDENCE_DIR="${QW002_EVIDENCE_DIR:-$ROOT/.opsforge/evidence/qw-002}"
QUEUE_NAME="${QW002_QUEUE_NAME:-nightwatch-jobs}"
BASELINE_CUSTOMER="opsforge-qw002-baseline"
INCIDENT_CUSTOMER="opsforge-qw002-incident"
FAULT_TABLE="opsforge_qw002_fault_control"
FAULT_FUNCTION="opsforge_qw002_fail_processing"
FAULT_TRIGGER="opsforge_qw002_processing_failure"

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
  compose exec -T rabbitmq rabbitmqctl -q list_queues name messages messages_ready messages_unacknowledged consumers \
    | awk -v queue="$QUEUE_NAME" '$1 == queue {print $2, $3, $4, $5}'
}

wait_for_api_ready() {
  for _ in {1..60}; do
    local status
    status=$(curl -sS -o /tmp/qw002-ready.json -w '%{http_code}' "$API_URL/health/ready" 2>/dev/null || true)
    if [[ "$status" = "200" ]]; then
      return 0
    fi
    sleep 1
  done
  compose ps -a
  compose logs --no-color api worker rabbitmq db redis || true
  echo "QW-002 API did not become ready" >&2
  return 1
}

wait_for_worker_healthy() {
  local container
  container="${OPSFORGE_CONTAINER_PREFIX:-nightwatch-qw002}-worker"
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
  echo "QW-002 worker did not become healthy" >&2
  return 1
}

wait_for_consumer_count() {
  local expected="$1"
  for _ in {1..40}; do
    local total ready unacked consumers
    read -r total ready unacked consumers <<<"$(queue_state || true)"
    if [[ -n "${consumers:-}" && "$consumers" = "$expected" ]]; then
      return 0
    fi
    sleep 0.5
  done
  queue_state || true
  echo "QW-002 expected RabbitMQ consumer count $expected" >&2
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
    echo "QW-002 ticket creation failed with HTTP $status" >&2
    return 1
  fi

  python3 - "$body" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
print(payload["id"])
PY
}

request_id_from_headers() {
  awk 'tolower($1) == "x-request-id:" {gsub("\r", "", $2); print $2}' "$1" | tail -1
}

ticket_status() {
  local ticket_id="$1"
  psql_cmd -Atc "SELECT processing_status FROM tickets WHERE id = $ticket_id;"
}

wait_for_ticket_status() {
  local ticket_id="$1"
  local expected="$2"
  for _ in {1..80}; do
    local state
    state=$(ticket_status "$ticket_id" 2>/dev/null || true)
    if [[ "$state" = "$expected" ]]; then
      return 0
    fi
    sleep 0.25
  done
  echo "QW-002 ticket $ticket_id did not reach processing_status=$expected" >&2
  return 1
}

capture_queue_state() {
  local file="$1"
  local total ready unacked consumers
  read -r total ready unacked consumers <<<"$(queue_state)"
  printf 'messages=%s\nmessages_ready=%s\nmessages_unacknowledged=%s\nconsumers=%s\n' \
    "$total" "$ready" "$unacked" "$consumers" | tee "$file"
}

capture_worker_metrics() {
  local file="$1"
  compose exec -T worker python -c '
import urllib.request
print(urllib.request.urlopen("http://127.0.0.1:9100/metrics", timeout=3).read().decode(), end="")
' > "$file"
}

failure_count_for_request() {
  local request_id="$1"
  compose logs --no-color worker 2>&1 \
    | grep -F "$request_id" \
    | grep -c '"event":"job_failed"' || true
}

wait_for_failure_count() {
  local request_id="$1"
  local minimum="$2"
  for _ in {1..80}; do
    local count
    count=$(failure_count_for_request "$request_id")
    if (( count >= minimum )); then
      printf '%s\n' "$count"
      return 0
    fi
    sleep 0.25
  done
  compose logs --no-color worker || true
  echo "QW-002 did not observe at least $minimum correlated processing failures" >&2
  return 1
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
  baseline_ticket=$(create_ticket "$BASELINE_CUSTOMER" "QW-002 healthy processing baseline" "baseline-create")
  printf '%s\n' "$baseline_ticket" > "$EVIDENCE_DIR/baseline-ticket-id.txt"
  wait_for_ticket_status "$baseline_ticket" processed
  capture_queue_state "$EVIDENCE_DIR/baseline-queue-state-after.txt"

  if ! grep -qx 'messages=0' "$EVIDENCE_DIR/baseline-queue-state-after.txt"; then
    echo "QW-002 baseline queue did not drain" >&2
    return 1
  fi
  if ! grep -qx 'consumers=1' "$EVIDENCE_DIR/baseline-queue-state-after.txt"; then
    echo "QW-002 baseline requires one live consumer" >&2
    return 1
  fi

  capture_worker_metrics "$EVIDENCE_DIR/baseline-worker-metrics.txt"
  echo "QW-002 baseline verified: consumer is healthy and normal ticket processing completes."
}

inject() {
  psql_cmd <<SQL
DROP TRIGGER IF EXISTS ${FAULT_TRIGGER} ON tickets;
DROP FUNCTION IF EXISTS ${FAULT_FUNCTION}();
DROP TABLE IF EXISTS ${FAULT_TABLE};

CREATE TABLE ${FAULT_TABLE} (
  id integer PRIMARY KEY CHECK (id = 1),
  enabled boolean NOT NULL
);

INSERT INTO ${FAULT_TABLE} (id, enabled) VALUES (1, true);

CREATE FUNCTION ${FAULT_FUNCTION}()
RETURNS trigger
LANGUAGE plpgsql
AS \$\$
DECLARE
  fault_enabled boolean;
BEGIN
  SELECT enabled INTO fault_enabled
  FROM ${FAULT_TABLE}
  WHERE id = 1;

  IF fault_enabled
     AND NEW.customer_id = '${INCIDENT_CUSTOMER}'
     AND NEW.processing_status = 'processed'
     AND OLD.processing_status IS DISTINCT FROM NEW.processing_status THEN
    PERFORM pg_sleep(0.35);
    RAISE EXCEPTION 'OPSFORGE QW-002 simulated transient processing failure';
  END IF;

  RETURN NEW;
END;
\$\$;

CREATE TRIGGER ${FAULT_TRIGGER}
BEFORE UPDATE OF processing_status ON tickets
FOR EACH ROW
EXECUTE FUNCTION ${FAULT_FUNCTION}();
SQL

  psql_cmd -Atc "SELECT enabled FROM ${FAULT_TABLE} WHERE id = 1;" \
    | tee "$EVIDENCE_DIR/incident-fault-control.txt"
  wait_for_consumer_count 1
  echo "QW-002 fault injected: ticket-scoped processing failure enabled while worker and broker remain online."
}

diagnose() {
  local ticket_id request_id failure_count ready_status queue_status db_ok redis_ok processing
  local total ready unacked consumers

  ticket_id=$(create_ticket "$INCIDENT_CUSTOMER" "QW-002 transient worker processing failure" "incident-create")
  printf '%s\n' "$ticket_id" > "$EVIDENCE_DIR/incident-ticket-id.txt"
  request_id=$(request_id_from_headers "$EVIDENCE_DIR/incident-create-headers.txt")
  printf '%s\n' "$request_id" > "$EVIDENCE_DIR/incident-request-id.txt"

  if [[ -z "$request_id" ]]; then
    echo "QW-002 request ID missing from incident response" >&2
    return 1
  fi

  failure_count=$(wait_for_failure_count "$request_id" 3)
  printf '%s\n' "$failure_count" | tee "$EVIDENCE_DIR/incident-failure-count.txt"

  processing=$(ticket_status "$ticket_id")
  printf '%s\n' "$processing" | tee "$EVIDENCE_DIR/incident-processing-status.txt"
  if [[ "$processing" != "queued" ]]; then
    echo "QW-002 expected target ticket to remain queued while processing fault is active" >&2
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
    echo "QW-002 expected API, RabbitMQ, PostgreSQL, and Redis health checks to remain healthy" >&2
    return 1
  fi

  compose exec -T rabbitmq rabbitmq-diagnostics -q ping \
    | tee "$EVIDENCE_DIR/incident-rabbitmq-ping.txt"

  capture_queue_state "$EVIDENCE_DIR/incident-queue-state.txt"
  read -r total ready unacked consumers <<<"$(queue_state)"
  if [[ "$consumers" != "1" ]] || (( total < 1 )); then
    echo "QW-002 expected one consumer and the failing message to remain in ready/unacked queue state" >&2
    return 1
  fi

  compose logs --no-color worker > "$EVIDENCE_DIR/incident-worker.log" 2>&1 || true
  if ! grep -F "$request_id" "$EVIDENCE_DIR/incident-worker.log" | grep -q '"event":"job_failed"'; then
    echo "QW-002 correlated worker failure evidence is missing" >&2
    return 1
  fi
  if ! grep -q 'OPSFORGE QW-002 simulated transient processing failure' "$EVIDENCE_DIR/incident-worker.log"; then
    echo "QW-002 expected processing exception text is missing" >&2
    return 1
  fi
  if grep -F "$request_id" "$EVIDENCE_DIR/incident-worker.log" | grep -q '"event":"job_completed"'; then
    echo "QW-002 target job unexpectedly completed while fault remained active" >&2
    return 1
  fi

  capture_worker_metrics "$EVIDENCE_DIR/incident-worker-metrics.txt"
  psql_cmd -P pager=off -c "
    SELECT id, customer_id, processing_status, processed_at, request_id
    FROM tickets
    WHERE id = $ticket_id;
  " | tee "$EVIDENCE_DIR/incident-ticket-db-state.txt"

  echo "QW-002 diagnosis verified: live consumer repeatedly receives a valid job, processing fails, and the message is requeued while dependencies remain healthy."
}

recover() {
  local ticket_id
  ticket_id=$(cat "$EVIDENCE_DIR/incident-ticket-id.txt")

  psql_cmd -c "UPDATE ${FAULT_TABLE} SET enabled = false WHERE id = 1;" \
    | tee "$EVIDENCE_DIR/recovery-fault-disable.txt"

  wait_for_ticket_status "$ticket_id" processed
  echo "QW-002 transient processing condition cleared; the existing consumer retried the same message to completion."
}

verify() {
  local ticket_id request_id customer_status processing total ready unacked consumers
  local worker_before worker_after api_before api_after failures completions

  ticket_id=$(cat "$EVIDENCE_DIR/incident-ticket-id.txt")
  request_id=$(cat "$EVIDENCE_DIR/incident-request-id.txt")

  customer_status=$(curl -sS -o "$EVIDENCE_DIR/post-recovery-ticket.json" -w '%{http_code}' \
    -H "X-Customer-ID: $INCIDENT_CUSTOMER" \
    "$API_URL/api/tickets/$ticket_id")
  printf '%s\n' "$customer_status" > "$EVIDENCE_DIR/post-recovery-ticket-http-status.txt"
  if [[ "$customer_status" != "200" ]]; then
    echo "QW-002 recovered customer ticket read failed" >&2
    return 1
  fi

  processing=$(ticket_status "$ticket_id")
  printf '%s\n' "$processing" | tee "$EVIDENCE_DIR/post-recovery-processing-status.txt"
  if [[ "$processing" != "processed" ]]; then
    echo "QW-002 target ticket did not complete after fault removal" >&2
    return 1
  fi

  capture_queue_state "$EVIDENCE_DIR/post-recovery-queue-state.txt"
  read -r total ready unacked consumers <<<"$(queue_state)"
  if [[ "$total" != "0" || "$ready" != "0" || "$unacked" != "0" || "$consumers" != "1" ]]; then
    echo "QW-002 queue did not return to empty state with one live consumer" >&2
    return 1
  fi

  compose logs --no-color worker > "$EVIDENCE_DIR/post-recovery-worker.log" 2>&1 || true
  failures=$(grep -F "$request_id" "$EVIDENCE_DIR/post-recovery-worker.log" | grep -c '"event":"job_failed"' || true)
  completions=$(grep -F "$request_id" "$EVIDENCE_DIR/post-recovery-worker.log" | grep -c '"event":"job_completed"' || true)
  printf 'correlated_failures=%s\ncorrelated_completions=%s\n' "$failures" "$completions" \
    | tee "$EVIDENCE_DIR/post-recovery-retry-summary.txt"

  if (( failures < 3 )) || [[ "$completions" != "1" ]]; then
    echo "QW-002 expected repeated correlated failures followed by exactly one completion" >&2
    return 1
  fi

  worker_before=$(awk -F= '/worker_container_id/ {print $2}' "$EVIDENCE_DIR/baseline-runtime-identity.txt")
  worker_after=$(compose ps -q worker)
  api_before=$(awk -F= '/api_container_id/ {print $2}' "$EVIDENCE_DIR/baseline-runtime-identity.txt")
  api_after=$(compose ps -q api)
  printf 'worker_container_before=%s\nworker_container_after=%s\napi_container_before=%s\napi_container_after=%s\n' \
    "$worker_before" "$worker_after" "$api_before" "$api_after" \
    | tee "$EVIDENCE_DIR/post-recovery-runtime-identity.txt"

  if [[ "$worker_before" != "$worker_after" || "$api_before" != "$api_after" ]]; then
    echo "QW-002 recovery must not restart or redeploy worker/API containers" >&2
    return 1
  fi

  capture_worker_metrics "$EVIDENCE_DIR/post-recovery-worker-metrics.txt"
  curl -sS "$API_URL/health/ready" | tee "$EVIDENCE_DIR/post-recovery-readiness.json" >/dev/null
  psql_cmd -Atc 'SELECT 1;' | tee "$EVIDENCE_DIR/post-recovery-db-health.txt"
  compose exec -T rabbitmq rabbitmq-diagnostics -q ping \
    | tee "$EVIDENCE_DIR/post-recovery-rabbitmq-ping.txt"

  psql_cmd <<SQL
DROP TRIGGER IF EXISTS ${FAULT_TRIGGER} ON tickets;
DROP FUNCTION IF EXISTS ${FAULT_FUNCTION}();
DROP TABLE IF EXISTS ${FAULT_TABLE};
SQL

  echo "QW-002 recovery verified: same worker retried the same valid message successfully after the transient processing condition cleared."
}

exercise() {
  baseline
  inject
  diagnose
  recover
  verify
  echo "QW-002 exercise verified: processing failure and requeue behavior isolated from broker/consumer health and recovered without worker restart."
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
