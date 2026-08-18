#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:?usage: qw_incident_003.sh <baseline|inject|diagnose|recover|verify|exercise>}"
PROJECT_NAME="${OPSFORGE_PROJECT_NAME:-opsforge-qw003}"
POSTGRES_USER="${POSTGRES_USER:-nightwatch}"
POSTGRES_DB="${POSTGRES_DB:-nightwatch}"
API_URL="${QW003_API_URL:-http://127.0.0.1:${API_HOST_PORT:-18103}}"
EVIDENCE_DIR="${QW003_EVIDENCE_DIR:-$ROOT/.opsforge/evidence/qw-003}"
QUEUE_NAME="${QW003_QUEUE_NAME:-nightwatch-jobs}"
BASELINE_CUSTOMER="opsforge-qw003-baseline"
INCIDENT_CUSTOMER_PREFIX="opsforge-qw003-incident"
BATCH_SIZE="${QW003_BATCH_SIZE:-10}"
BATCH_COUNT="${QW003_BATCH_COUNT:-3}"
PROCESSING_DELAY_SECONDS="${QW003_PROCESSING_DELAY_SECONDS:-0.60}"
FAULT_TABLE="opsforge_qw003_delay_control"
FAULT_FUNCTION="opsforge_qw003_delay_processing"
FAULT_TRIGGER="opsforge_qw003_processing_delay"

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

capture_queue_state() {
  local file="$1"
  local total ready unacked consumers
  read -r total ready unacked consumers <<<"$(queue_state)"
  printf 'messages=%s\nmessages_ready=%s\nmessages_unacknowledged=%s\nconsumers=%s\n' \
    "$total" "$ready" "$unacked" "$consumers" | tee "$file"
}

queue_total_from_file() {
  awk -F= '$1 == "messages" {print $2}' "$1"
}

wait_for_api_ready() {
  for _ in {1..60}; do
    local status
    status=$(curl -sS -o /tmp/qw003-ready.json -w '%{http_code}' "$API_URL/health/ready" 2>/dev/null || true)
    if [[ "$status" = "200" ]]; then
      return 0
    fi
    sleep 1
  done
  compose ps -a
  compose logs --no-color api worker rabbitmq db redis || true
  echo "QW-003 API did not become ready" >&2
  return 1
}

wait_for_worker_healthy() {
  local container
  container="${OPSFORGE_CONTAINER_PREFIX:-nightwatch-qw003}-worker"
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
  echo "QW-003 worker did not become healthy" >&2
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
  echo "QW-003 expected RabbitMQ consumer count $expected" >&2
  return 1
}

create_ticket() {
  local customer="$1"
  local title="$2"
  local prefix="$3"
  local headers="$EVIDENCE_DIR/${prefix}-headers.txt"
  local body="$EVIDENCE_DIR/${prefix}-body.json"
  local status ticket_id request_id

  status=$(curl -sS -D "$headers" -o "$body" -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -H "X-Customer-ID: $customer" \
    -X POST "$API_URL/api/tickets" \
    -d "{\"title\":\"$title\",\"severity\":\"SEV3\"}")

  printf '%s\n' "$status" > "$EVIDENCE_DIR/${prefix}-http-status.txt"
  if [[ "$status" != "201" ]]; then
    cat "$body" >&2 || true
    echo "QW-003 ticket creation failed with HTTP $status" >&2
    return 1
  fi

  ticket_id=$(python3 - "$body" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
print(payload["id"])
PY
)
  request_id=$(awk 'tolower($1) == "x-request-id:" {gsub("\r", "", $2); print $2}' "$headers" | tail -1)
  printf '%s|%s\n' "$ticket_id" "$request_id"
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
  echo "QW-003 ticket $ticket_id did not reach processing_status=$expected" >&2
  return 1
}

capture_processing_counts() {
  local file="$1"
  psql_cmd -At -F= -c "
    SELECT processing_status, count(*)
    FROM tickets
    WHERE customer_id LIKE '${INCIDENT_CUSTOMER_PREFIX}-%'
    GROUP BY processing_status
    ORDER BY processing_status;
  " | tee "$file"
}

capture_worker_metrics() {
  local file="$1"
  compose exec -T worker python -c '
import urllib.request
print(urllib.request.urlopen("http://127.0.0.1:9100/metrics", timeout=3).read().decode(), end="")
' > "$file"
}

capture_dependency_health() {
  local prefix="$1"
  local ready_status queue_status db_ok redis_ok
  ready_status=$(curl -sS -o "$EVIDENCE_DIR/${prefix}-readiness.json" -w '%{http_code}' "$API_URL/health/ready")
  queue_status=$(curl -sS -o "$EVIDENCE_DIR/${prefix}-queue-health.json" -w '%{http_code}' "$API_URL/queue-health")
  db_ok=$(psql_cmd -Atc 'SELECT 1;')
  redis_ok=$(compose exec -T redis redis-cli ping)
  printf 'readiness_http=%s\nqueue_health_http=%s\ndb_select_1=%s\nredis_ping=%s\n' \
    "$ready_status" "$queue_status" "$db_ok" "$redis_ok" \
    | tee "$EVIDENCE_DIR/${prefix}-dependency-health.txt"
  if [[ "$ready_status" != "200" || "$queue_status" != "200" || "$db_ok" != "1" || "$redis_ok" != "PONG" ]]; then
    echo "QW-003 expected API, PostgreSQL, Redis, and queue health to remain healthy" >&2
    return 1
  fi
  compose exec -T rabbitmq rabbitmq-diagnostics -q ping \
    | tee "$EVIDENCE_DIR/${prefix}-rabbitmq-ping.txt"
}

baseline() {
  wait_for_api_ready
  wait_for_worker_healthy
  wait_for_consumer_count 1

  local worker_container api_container baseline_result baseline_ticket
  worker_container=$(compose ps -q worker)
  api_container=$(compose ps -q api)
  printf 'worker_container_id=%s\napi_container_id=%s\n' "$worker_container" "$api_container" \
    | tee "$EVIDENCE_DIR/baseline-runtime-identity.txt"

  capture_queue_state "$EVIDENCE_DIR/baseline-queue-state-before.txt"
  baseline_result=$(create_ticket "$BASELINE_CUSTOMER" "QW-003 healthy throughput baseline" "baseline-create")
  baseline_ticket=${baseline_result%%|*}
  printf '%s\n' "$baseline_ticket" > "$EVIDENCE_DIR/baseline-ticket-id.txt"
  wait_for_ticket_status "$baseline_ticket" processed
  capture_queue_state "$EVIDENCE_DIR/baseline-queue-state-after.txt"

  if ! grep -qx 'messages=0' "$EVIDENCE_DIR/baseline-queue-state-after.txt"; then
    echo "QW-003 baseline queue did not drain" >&2
    return 1
  fi
  if ! grep -qx 'consumers=1' "$EVIDENCE_DIR/baseline-queue-state-after.txt"; then
    echo "QW-003 baseline requires one live consumer" >&2
    return 1
  fi

  capture_worker_metrics "$EVIDENCE_DIR/baseline-worker-metrics.txt"
  echo "QW-003 baseline verified: one live consumer drains normal work without backlog."
}

inject() {
  psql_cmd <<SQL
DROP TRIGGER IF EXISTS ${FAULT_TRIGGER} ON tickets;
DROP FUNCTION IF EXISTS ${FAULT_FUNCTION}();
DROP TABLE IF EXISTS ${FAULT_TABLE};

CREATE TABLE ${FAULT_TABLE} (
  id integer PRIMARY KEY CHECK (id = 1),
  enabled boolean NOT NULL,
  delay_seconds numeric NOT NULL CHECK (delay_seconds >= 0)
);

INSERT INTO ${FAULT_TABLE} (id, enabled, delay_seconds)
VALUES (1, true, ${PROCESSING_DELAY_SECONDS});

CREATE FUNCTION ${FAULT_FUNCTION}()
RETURNS trigger
LANGUAGE plpgsql
AS \$\$
DECLARE
  fault_enabled boolean;
  configured_delay numeric;
BEGIN
  SELECT enabled, delay_seconds
  INTO fault_enabled, configured_delay
  FROM ${FAULT_TABLE}
  WHERE id = 1;

  IF fault_enabled
     AND NEW.customer_id LIKE '${INCIDENT_CUSTOMER_PREFIX}-%'
     AND NEW.processing_status = 'processed'
     AND OLD.processing_status IS DISTINCT FROM NEW.processing_status THEN
    PERFORM pg_sleep(configured_delay::double precision);
  END IF;

  RETURN NEW;
END;
\$\$;

CREATE TRIGGER ${FAULT_TRIGGER}
BEFORE UPDATE OF processing_status ON tickets
FOR EACH ROW
EXECUTE FUNCTION ${FAULT_FUNCTION}();
SQL

  psql_cmd -At -F= -c "SELECT enabled, delay_seconds FROM ${FAULT_TABLE} WHERE id = 1;" \
    | tee "$EVIDENCE_DIR/incident-delay-control.txt"
  wait_for_consumer_count 1
  echo "QW-003 fault injected: ticket-scoped processing delay enabled while worker and broker remain healthy."
}

diagnose() {
  : > "$EVIDENCE_DIR/incident-tickets.tsv"
  local total_target=$((BATCH_SIZE * BATCH_COUNT))
  local sequence=0 batch item result ticket_id request_id customer
  local burst_start burst_end burst_seconds arrival_rate

  burst_start=$(python3 - <<'PY'
import time
print(time.time())
PY
)

  for ((batch=1; batch<=BATCH_COUNT; batch++)); do
    for ((item=1; item<=BATCH_SIZE; item++)); do
      sequence=$((sequence + 1))
      customer="${INCIDENT_CUSTOMER_PREFIX}-${sequence}"
      result=$(create_ticket "$customer" "QW-003 backlog ticket ${sequence}" "incident-${sequence}")
      ticket_id=${result%%|*}
      request_id=${result#*|}
      if [[ -z "$request_id" ]]; then
        echo "QW-003 request ID missing for incident ticket $sequence" >&2
        return 1
      fi
      printf '%s\t%s\t%s\t%s\n' "$sequence" "$ticket_id" "$customer" "$request_id" \
        >> "$EVIDENCE_DIR/incident-tickets.tsv"
    done

    capture_queue_state "$EVIDENCE_DIR/incident-queue-sample-${batch}.txt"
    capture_processing_counts "$EVIDENCE_DIR/incident-processing-sample-${batch}.txt"
  done

  burst_end=$(python3 - <<'PY'
import time
print(time.time())
PY
)
  read -r burst_seconds arrival_rate < <(python3 - "$burst_start" "$burst_end" "$total_target" <<'PY'
import sys
start, end, count = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])
duration = max(end - start, 0.001)
print(f"{duration:.3f} {count / duration:.3f}")
PY
)
  printf 'tickets_published=%s\nburst_seconds=%s\napprox_arrival_rate_per_second=%s\nprocessing_delay_seconds=%s\n' \
    "$total_target" "$burst_seconds" "$arrival_rate" "$PROCESSING_DELAY_SECONDS" \
    | tee "$EVIDENCE_DIR/incident-arrival-summary.txt"

  local q1 q2 q3
  q1=$(queue_total_from_file "$EVIDENCE_DIR/incident-queue-sample-1.txt")
  q2=$(queue_total_from_file "$EVIDENCE_DIR/incident-queue-sample-2.txt")
  q3=$(queue_total_from_file "$EVIDENCE_DIR/incident-queue-sample-3.txt")
  printf 'sample_1_messages=%s\nsample_2_messages=%s\nsample_3_messages=%s\n' "$q1" "$q2" "$q3" \
    | tee "$EVIDENCE_DIR/incident-backlog-growth.txt"

  if (( q1 < 3 || q2 <= q1 || q3 <= q2 || q3 < 15 )); then
    echo "QW-003 expected backlog to grow across all three arrival batches and reach at least 15 messages" >&2
    return 1
  fi

  sleep 2
  capture_queue_state "$EVIDENCE_DIR/incident-progress-queue-state.txt"
  capture_processing_counts "$EVIDENCE_DIR/incident-progress-processing-counts.txt"
  local q_progress total ready unacked consumers
  q_progress=$(queue_total_from_file "$EVIDENCE_DIR/incident-progress-queue-state.txt")
  read -r total ready unacked consumers <<<"$(queue_state)"

  if [[ "$consumers" != "1" ]] || (( q_progress <= 0 || q_progress >= q3 )); then
    echo "QW-003 expected one live consumer making progress while a non-zero backlog remains" >&2
    return 1
  fi

  capture_dependency_health "incident"
  capture_worker_metrics "$EVIDENCE_DIR/incident-worker-metrics.txt"
  compose logs --no-color worker > "$EVIDENCE_DIR/incident-worker.log" 2>&1 || true

  local correlated_failures=0 correlated_completions=0 req
  while IFS=$'\t' read -r _ _ _ req; do
    correlated_failures=$((correlated_failures + $(grep -F "$req" "$EVIDENCE_DIR/incident-worker.log" | grep -c '"event":"job_failed"' || true)))
    correlated_completions=$((correlated_completions + $(grep -F "$req" "$EVIDENCE_DIR/incident-worker.log" | grep -c '"event":"job_completed"' || true)))
  done < "$EVIDENCE_DIR/incident-tickets.tsv"
  printf 'correlated_failures=%s\ncorrelated_completions_during_incident=%s\n' \
    "$correlated_failures" "$correlated_completions" \
    | tee "$EVIDENCE_DIR/incident-worker-outcome-summary.txt"

  if (( correlated_failures != 0 || correlated_completions < 1 )); then
    echo "QW-003 requires successful but insufficient processing: zero failures and some completed jobs while backlog remains" >&2
    return 1
  fi

  local last_ticket last_status
  last_ticket=$(tail -1 "$EVIDENCE_DIR/incident-tickets.tsv" | cut -f2)
  last_status=$(ticket_status "$last_ticket")
  printf 'last_ticket_id=%s\nlast_ticket_processing_status=%s\n' "$last_ticket" "$last_status" \
    | tee "$EVIDENCE_DIR/incident-last-ticket-state.txt"
  if [[ "$last_status" != "queued" ]]; then
    echo "QW-003 expected the tail of the burst to remain queued during backlog diagnosis" >&2
    return 1
  fi

  echo "QW-003 diagnosis verified: arrivals exceed successful worker throughput, backlog grows with one healthy consumer, and the worker continues making progress without failures."
}

recover() {
  psql_cmd -c "UPDATE ${FAULT_TABLE} SET enabled = false WHERE id = 1;" \
    | tee "$EVIDENCE_DIR/recovery-delay-disable.txt"

  local started ended drain_seconds total ready unacked consumers queued_count
  started=$(python3 - <<'PY'
import time
print(time.time())
PY
)

  for _ in {1..160}; do
    read -r total ready unacked consumers <<<"$(queue_state || true)"
    queued_count=$(psql_cmd -Atc "SELECT count(*) FROM tickets WHERE customer_id LIKE '${INCIDENT_CUSTOMER_PREFIX}-%' AND processing_status <> 'processed';" 2>/dev/null || true)
    if [[ "$total" = "0" && "$queued_count" = "0" && "$consumers" = "1" ]]; then
      break
    fi
    sleep 0.25
  done

  read -r total ready unacked consumers <<<"$(queue_state)"
  queued_count=$(psql_cmd -Atc "SELECT count(*) FROM tickets WHERE customer_id LIKE '${INCIDENT_CUSTOMER_PREFIX}-%' AND processing_status <> 'processed';")
  if [[ "$total" != "0" || "$queued_count" != "0" || "$consumers" != "1" ]]; then
    capture_queue_state "$EVIDENCE_DIR/recovery-timeout-queue-state.txt" || true
    capture_processing_counts "$EVIDENCE_DIR/recovery-timeout-processing-counts.txt" || true
    echo "QW-003 backlog did not drain after the confirmed throughput constraint was removed" >&2
    return 1
  fi

  ended=$(python3 - <<'PY'
import time
print(time.time())
PY
)
  drain_seconds=$(python3 - "$started" "$ended" <<'PY'
import sys
print(f"{float(sys.argv[2]) - float(sys.argv[1]):.3f}")
PY
)
  printf 'drain_seconds_after_delay_removed=%s\n' "$drain_seconds" \
    | tee "$EVIDENCE_DIR/recovery-drain-duration.txt"
  echo "QW-003 throughput constraint cleared; the existing consumer drained all original queued work."
}

verify() {
  local total ready unacked consumers processed_count expected_count
  expected_count=$((BATCH_SIZE * BATCH_COUNT))

  capture_queue_state "$EVIDENCE_DIR/post-recovery-queue-state.txt"
  read -r total ready unacked consumers <<<"$(queue_state)"
  if [[ "$total" != "0" || "$ready" != "0" || "$unacked" != "0" || "$consumers" != "1" ]]; then
    echo "QW-003 queue did not recover to empty state with one live consumer" >&2
    return 1
  fi

  capture_processing_counts "$EVIDENCE_DIR/post-recovery-processing-counts.txt"
  processed_count=$(psql_cmd -Atc "SELECT count(*) FROM tickets WHERE customer_id LIKE '${INCIDENT_CUSTOMER_PREFIX}-%' AND processing_status = 'processed';")
  printf 'expected_incident_tickets=%s\nprocessed_incident_tickets=%s\n' "$expected_count" "$processed_count" \
    | tee "$EVIDENCE_DIR/post-recovery-ticket-summary.txt"
  if [[ "$processed_count" != "$expected_count" ]]; then
    echo "QW-003 not all incident tickets reached processed state" >&2
    return 1
  fi

  compose logs --no-color worker > "$EVIDENCE_DIR/post-recovery-worker.log" 2>&1 || true
  local failures=0 completions=0 req
  while IFS=$'\t' read -r _ _ _ req; do
    failures=$((failures + $(grep -F "$req" "$EVIDENCE_DIR/post-recovery-worker.log" | grep -c '"event":"job_failed"' || true)))
    completions=$((completions + $(grep -F "$req" "$EVIDENCE_DIR/post-recovery-worker.log" | grep -c '"event":"job_completed"' || true)))
  done < "$EVIDENCE_DIR/incident-tickets.tsv"
  printf 'correlated_failures=%s\ncorrelated_completions=%s\n' "$failures" "$completions" \
    | tee "$EVIDENCE_DIR/post-recovery-worker-outcome-summary.txt"
  if (( failures != 0 || completions != expected_count )); then
    echo "QW-003 expected exactly one successful completion per incident request and zero failures" >&2
    return 1
  fi

  local worker_before worker_after api_before api_after
  worker_before=$(awk -F= '/worker_container_id/ {print $2}' "$EVIDENCE_DIR/baseline-runtime-identity.txt")
  api_before=$(awk -F= '/api_container_id/ {print $2}' "$EVIDENCE_DIR/baseline-runtime-identity.txt")
  worker_after=$(compose ps -q worker)
  api_after=$(compose ps -q api)
  printf 'worker_container_before=%s\nworker_container_after=%s\napi_container_before=%s\napi_container_after=%s\n' \
    "$worker_before" "$worker_after" "$api_before" "$api_after" \
    | tee "$EVIDENCE_DIR/post-recovery-runtime-identity.txt"
  if [[ "$worker_before" != "$worker_after" || "$api_before" != "$api_after" ]]; then
    echo "QW-003 expected recovery without worker or API restart/redeployment" >&2
    return 1
  fi

  local last_ticket last_customer customer_status
  last_ticket=$(tail -1 "$EVIDENCE_DIR/incident-tickets.tsv" | cut -f2)
  last_customer=$(tail -1 "$EVIDENCE_DIR/incident-tickets.tsv" | cut -f3)
  customer_status=$(curl -sS -o "$EVIDENCE_DIR/post-recovery-last-ticket.json" -w '%{http_code}' \
    -H "X-Customer-ID: $last_customer" \
    "$API_URL/api/tickets/$last_ticket")
  printf '%s\n' "$customer_status" > "$EVIDENCE_DIR/post-recovery-last-ticket-http-status.txt"
  if [[ "$customer_status" != "200" ]]; then
    echo "QW-003 customer verification for the tail ticket failed" >&2
    return 1
  fi

  capture_dependency_health "post-recovery"
  capture_worker_metrics "$EVIDENCE_DIR/post-recovery-worker-metrics.txt"

  psql_cmd <<SQL
DROP TRIGGER IF EXISTS ${FAULT_TRIGGER} ON tickets;
DROP FUNCTION IF EXISTS ${FAULT_FUNCTION}();
DROP TABLE IF EXISTS ${FAULT_TABLE};
SQL

  echo "QW-003 recovery verified: backlog drained, all original tickets completed successfully, one consumer remained active, and worker/API runtime identities stayed unchanged."
}

exercise() {
  baseline
  inject
  diagnose
  recover
  verify
  echo "QW-003 exercise verified: queue backlog isolated as arrival-rate versus processing-throughput mismatch and recovered without restart or redeployment."
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
