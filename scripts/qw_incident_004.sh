#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:?usage: qw_incident_004.sh <baseline|inject|diagnose|recover|verify|exercise>}"
PROJECT_NAME="${OPSFORGE_PROJECT_NAME:-opsforge-qw004}"
POSTGRES_USER="${POSTGRES_USER:-nightwatch}"
POSTGRES_DB="${POSTGRES_DB:-nightwatch}"
API_URL="${QW004_API_URL:-http://127.0.0.1:${API_HOST_PORT:-18104}}"
EVIDENCE_DIR="${QW004_EVIDENCE_DIR:-$ROOT/.opsforge/evidence/qw-004}"
QUEUE_NAME="${QW004_QUEUE_NAME:-nightwatch-jobs}"
QUARANTINE_QUEUE="${QW004_QUARANTINE_QUEUE:-nightwatch-jobs.quarantine}"
BASELINE_CUSTOMER="opsforge-qw004-baseline"
POISON_CUSTOMER="opsforge-qw004-poison"
HEALTHY_CUSTOMER="opsforge-qw004-healthy"
HEALTHY_COUNT="${QW004_HEALTHY_COUNT:-3}"

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
  local queue="$1"
  compose exec -T rabbitmq rabbitmqctl -q list_queues name messages messages_ready messages_unacknowledged consumers \
    | awk -v queue="$queue" '$1 == queue {print $2, $3, $4, $5}'
}

capture_queue_state() {
  local queue="$1"
  local file="$2"
  local total ready unacked consumers
  read -r total ready unacked consumers <<<"$(queue_state "$queue")"
  printf 'queue=%s\nmessages=%s\nmessages_ready=%s\nmessages_unacknowledged=%s\nconsumers=%s\n' \
    "$queue" "$total" "$ready" "$unacked" "$consumers" | tee "$file"
}

wait_for_api_ready() {
  for _ in {1..60}; do
    local status
    status=$(curl -sS -o /tmp/qw004-ready.json -w '%{http_code}' "$API_URL/health/ready" 2>/dev/null || true)
    if [[ "$status" = "200" ]]; then
      return 0
    fi
    sleep 1
  done
  compose ps -a
  compose logs --no-color api worker rabbitmq db redis || true
  echo "QW-004 API did not become ready" >&2
  return 1
}

wait_for_worker_healthy() {
  local container="${OPSFORGE_CONTAINER_PREFIX:-nightwatch-qw004}-worker"
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
  echo "QW-004 worker did not become healthy" >&2
  return 1
}

wait_for_consumer_count() {
  local expected="$1"
  for _ in {1..60}; do
    local total ready unacked consumers
    read -r total ready unacked consumers <<<"$(queue_state "$QUEUE_NAME" || true)"
    if [[ -n "${consumers:-}" && "$consumers" = "$expected" ]]; then
      return 0
    fi
    sleep 0.5
  done
  queue_state "$QUEUE_NAME" || true
  echo "QW-004 expected RabbitMQ consumer count $expected" >&2
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
    echo "QW-004 ticket creation failed with HTTP $status" >&2
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
  for _ in {1..120}; do
    local state
    state=$(ticket_status "$ticket_id" 2>/dev/null || true)
    if [[ "$state" = "$expected" ]]; then
      return 0
    fi
    sleep 0.25
  done
  echo "QW-004 ticket $ticket_id did not reach processing_status=$expected" >&2
  return 1
}

wait_for_quarantine_count() {
  local expected="$1"
  for _ in {1..120}; do
    local total ready unacked consumers
    read -r total ready unacked consumers <<<"$(queue_state "$QUARANTINE_QUEUE" || true)"
    if [[ -n "${total:-}" && "$total" = "$expected" ]]; then
      return 0
    fi
    sleep 0.25
  done
  queue_state "$QUARANTINE_QUEUE" || true
  echo "QW-004 quarantine queue did not reach messages=$expected" >&2
  return 1
}

wait_for_main_queue_empty() {
  for _ in {1..120}; do
    local total ready unacked consumers
    read -r total ready unacked consumers <<<"$(queue_state "$QUEUE_NAME" || true)"
    if [[ -n "${total:-}" && "$total" = "0" && "$ready" = "0" && "$unacked" = "0" && "$consumers" = "1" ]]; then
      return 0
    fi
    sleep 0.25
  done
  queue_state "$QUEUE_NAME" || true
  echo "QW-004 main queue did not drain to zero with one live consumer" >&2
  return 1
}

capture_worker_metrics() {
  local file="$1"
  compose exec -T worker python -c '
import urllib.request
print(urllib.request.urlopen("http://127.0.0.1:9100/metrics", timeout=3).read().decode(), end="")
' > "$file"
}

max_retries() {
  compose exec -T worker sh -c 'printf "%s\n" "${WORKER_MAX_RETRIES:-5}"'
}

worker_log_count() {
  local request_id="$1"
  local event="$2"
  compose logs --no-color worker 2>&1 \
    | grep -F "$request_id" \
    | grep -c "\"event\":\"$event\"" || true
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

  capture_queue_state "$QUEUE_NAME" "$EVIDENCE_DIR/baseline-main-queue-before.txt"
  capture_queue_state "$QUARANTINE_QUEUE" "$EVIDENCE_DIR/baseline-quarantine-before.txt"

  baseline_ticket=$(create_ticket "$BASELINE_CUSTOMER" "QW-004 healthy processing baseline" "baseline-create")
  printf '%s\n' "$baseline_ticket" > "$EVIDENCE_DIR/baseline-ticket-id.txt"
  wait_for_ticket_status "$baseline_ticket" processed
  wait_for_main_queue_empty

  capture_queue_state "$QUEUE_NAME" "$EVIDENCE_DIR/baseline-main-queue-after.txt"
  capture_queue_state "$QUARANTINE_QUEUE" "$EVIDENCE_DIR/baseline-quarantine-after.txt"
  capture_worker_metrics "$EVIDENCE_DIR/baseline-worker-metrics.txt"

  if ! grep -qx 'messages=0' "$EVIDENCE_DIR/baseline-quarantine-after.txt"; then
    echo "QW-004 baseline quarantine queue must be empty" >&2
    return 1
  fi

  echo "QW-004 baseline verified: normal work completes, one consumer is active, and quarantine is empty."
}

inject() {
  local poison_request_id poison_event_id poison_ticket_id retry_limit
  poison_request_id=$(python3 -c 'import uuid; print(uuid.uuid4())')
  poison_event_id=$(python3 -c 'import uuid; print(uuid.uuid4())')

  poison_ticket_id=$(psql_cmd -Atq -c "
    INSERT INTO tickets (
      title, severity, status, processing_status, customer_id, request_id
    )
    VALUES (
      'QW-004 permanently invalid queue event',
      'SEV2',
      'Open',
      'queued',
      '$POISON_CUSTOMER',
      '$poison_request_id'
    )
    RETURNING id;
  ")

  if [[ ! "$poison_ticket_id" =~ ^[0-9]+$ ]]; then
    echo "QW-004 poison ticket ID is not numeric: $poison_ticket_id" >&2
    return 1
  fi

  printf '%s\n' "$poison_ticket_id" > "$EVIDENCE_DIR/poison-ticket-id.txt"
  printf '%s\n' "$poison_request_id" > "$EVIDENCE_DIR/poison-request-id.txt"
  printf '%s\n' "$poison_event_id" > "$EVIDENCE_DIR/poison-event-id.txt"

  retry_limit=$(max_retries)
  printf '%s\n' "$retry_limit" > "$EVIDENCE_DIR/worker-max-retries.txt"

  compose exec -T worker python - "$QUEUE_NAME" "$poison_ticket_id" "$poison_request_id" "$poison_event_id" <<'PY' \
    | tee "$EVIDENCE_DIR/poison-publish-summary.json"
import json, os, sys
import pika

queue, ticket_id, request_id, event_id = sys.argv[1:5]
credentials = pika.PlainCredentials(os.environ["RABBITMQ_USER"], os.environ["RABBITMQ_PASSWORD"])
conn = pika.BlockingConnection(pika.ConnectionParameters(
    host=os.environ.get("RABBITMQ_HOST", "nightwatch-rabbit"),
    credentials=credentials,
    heartbeat=30,
))
ch = conn.channel()
ch.queue_declare(queue=queue, durable=True)
ch.confirm_delivery()

payload = {
    "event_id": event_id,
    "event_type": "ticket.unsupported",
    "ticket_id": int(ticket_id),
    "customer_id": "opsforge-qw004-poison",
    "request_id": request_id,
}
body = json.dumps(payload, separators=(",", ":"))
ch.basic_publish(
    exchange="",
    routing_key=queue,
    body=body,
    properties=pika.BasicProperties(
        delivery_mode=2,
        content_type="application/json",
        message_id=event_id,
        headers={"x-request-id": request_id},
    ),
    mandatory=True,
)
conn.close()
print(json.dumps({"queue": queue, "ticket_id": int(ticket_id), "request_id": request_id, "event_id": event_id, "event_type": payload["event_type"]}, separators=(",", ":")))
PY

  : > "$EVIDENCE_DIR/healthy-ticket-ids.txt"
  : > "$EVIDENCE_DIR/healthy-request-ids.txt"
  for index in $(seq 1 "$HEALTHY_COUNT"); do
    local ticket request_id
    ticket=$(create_ticket "$HEALTHY_CUSTOMER" "QW-004 healthy work $index" "healthy-$index")
    request_id=$(request_id_from_headers "$EVIDENCE_DIR/healthy-$index-headers.txt")
    printf '%s\n' "$ticket" >> "$EVIDENCE_DIR/healthy-ticket-ids.txt"
    printf '%s\n' "$request_id" >> "$EVIDENCE_DIR/healthy-request-ids.txt"
  done

  echo "QW-004 poison event injected with a real ticket reference and a permanently unsupported event type."
}

diagnose() {
  local poison_ticket_id poison_request_id retry_limit
  local failures retries quarantined completions
  local ready_status queue_status db_ok redis_ok
  poison_ticket_id=$(cat "$EVIDENCE_DIR/poison-ticket-id.txt")
  poison_request_id=$(cat "$EVIDENCE_DIR/poison-request-id.txt")
  retry_limit=$(cat "$EVIDENCE_DIR/worker-max-retries.txt")

  wait_for_quarantine_count 1

  while IFS= read -r ticket_id; do
    wait_for_ticket_status "$ticket_id" processed
  done < "$EVIDENCE_DIR/healthy-ticket-ids.txt"
  wait_for_main_queue_empty

  if [[ "$(ticket_status "$poison_ticket_id")" != "queued" ]]; then
    echo "QW-004 poison ticket should remain queued after quarantine" >&2
    return 1
  fi
  printf '%s\n' "$(ticket_status "$poison_ticket_id")" | tee "$EVIDENCE_DIR/incident-poison-processing-status.txt"

  compose logs --no-color worker > "$EVIDENCE_DIR/incident-worker.log" 2>&1 || true
  failures=$(worker_log_count "$poison_request_id" job_failed)
  retries=$(worker_log_count "$poison_request_id" job_retry_scheduled)
  quarantined=$(worker_log_count "$poison_request_id" job_quarantined)
  completions=$(worker_log_count "$poison_request_id" job_completed)
  printf 'job_failed=%s\njob_retry_scheduled=%s\njob_quarantined=%s\njob_completed=%s\n' \
    "$failures" "$retries" "$quarantined" "$completions" \
    | tee "$EVIDENCE_DIR/incident-poison-outcomes.txt"

  if (( failures != retry_limit + 1 )); then
    echo "QW-004 expected $((retry_limit + 1)) poison failures, observed $failures" >&2
    return 1
  fi
  if (( retries != retry_limit )); then
    echo "QW-004 expected $retry_limit scheduled retries, observed $retries" >&2
    return 1
  fi
  if [[ "$quarantined" != "1" || "$completions" != "0" ]]; then
    echo "QW-004 poison message must quarantine exactly once and not complete before replay" >&2
    return 1
  fi

  capture_queue_state "$QUEUE_NAME" "$EVIDENCE_DIR/incident-main-queue-state.txt"
  capture_queue_state "$QUARANTINE_QUEUE" "$EVIDENCE_DIR/incident-quarantine-state.txt"

  ready_status=$(curl -sS -o "$EVIDENCE_DIR/incident-readiness.json" -w '%{http_code}' "$API_URL/health/ready")
  queue_status=$(curl -sS -o "$EVIDENCE_DIR/incident-queue-health.json" -w '%{http_code}' "$API_URL/queue-health")
  db_ok=$(psql_cmd -Atc 'SELECT 1;')
  redis_ok=$(compose exec -T redis redis-cli ping)
  printf 'readiness_http=%s\nqueue_health_http=%s\ndb_select_1=%s\nredis_ping=%s\n' \
    "$ready_status" "$queue_status" "$db_ok" "$redis_ok" \
    | tee "$EVIDENCE_DIR/incident-dependency-health.txt"
  if [[ "$ready_status" != "200" || "$queue_status" != "200" || "$db_ok" != "1" || "$redis_ok" != "PONG" ]]; then
    echo "QW-004 dependencies must remain healthy during poison-message isolation" >&2
    return 1
  fi
  compose exec -T rabbitmq rabbitmq-diagnostics -q ping \
    | tee "$EVIDENCE_DIR/incident-rabbitmq-ping.txt"

  psql_cmd -P pager=off -c "
    SELECT id, customer_id, processing_status, request_id
    FROM tickets
    WHERE id = $poison_ticket_id
       OR id IN ($(paste -sd, "$EVIDENCE_DIR/healthy-ticket-ids.txt"));
  " | tee "$EVIDENCE_DIR/incident-ticket-states.txt"

  capture_worker_metrics "$EVIDENCE_DIR/incident-worker-metrics.txt"
  wait_for_consumer_count 1

  echo "QW-004 diagnosis verified: one permanently invalid event exhausted bounded retries, quarantined exactly once, and healthy work continued through the same consumer."
}

recover() {
  local poison_request_id
  poison_request_id=$(cat "$EVIDENCE_DIR/poison-request-id.txt")

  compose exec -T worker python - "$QUEUE_NAME" "$QUARANTINE_QUEUE" "$poison_request_id" <<'PY' \
    | tee "$EVIDENCE_DIR/recovery-quarantine-replay.json"
import json, os, sys
import pika

main_queue, quarantine_queue, expected_request_id = sys.argv[1:4]
credentials = pika.PlainCredentials(os.environ["RABBITMQ_USER"], os.environ["RABBITMQ_PASSWORD"])
conn = pika.BlockingConnection(pika.ConnectionParameters(
    host=os.environ.get("RABBITMQ_HOST", "nightwatch-rabbit"),
    credentials=credentials,
    heartbeat=30,
))
ch = conn.channel()
ch.queue_declare(queue=main_queue, durable=True)
ch.queue_declare(queue=quarantine_queue, durable=True)
ch.confirm_delivery()

method, props, body = ch.basic_get(queue=quarantine_queue, auto_ack=False)
if method is None:
    raise SystemExit("QW-004 quarantine queue is empty")

event = json.loads(body)
headers = dict(props.headers or {})
request_id = headers.get("x-request-id") or event.get("request_id")
if request_id != expected_request_id:
    ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
    raise SystemExit(f"QW-004 unexpected quarantined request_id {request_id}")
if event.get("event_type") != "ticket.unsupported":
    ch.basic_nack(delivery_tag=method.delivery_tag, requeue=True)
    raise SystemExit(f"QW-004 unexpected quarantined event_type {event.get('event_type')}")

original_type = event["event_type"]
event["event_type"] = "ticket.created"
headers["x-opsforge-retry-count"] = 0
headers["x-opsforge-replayed-from"] = quarantine_queue
headers["x-opsforge-original-event-type"] = original_type

ch.basic_publish(
    exchange="",
    routing_key=main_queue,
    body=json.dumps(event, separators=(",", ":")),
    properties=pika.BasicProperties(
        delivery_mode=2,
        content_type=props.content_type or "application/json",
        message_id=props.message_id,
        correlation_id=props.correlation_id,
        headers=headers,
    ),
    mandatory=True,
)
ch.basic_ack(delivery_tag=method.delivery_tag)
conn.close()
print(json.dumps({
    "request_id": request_id,
    "ticket_id": event["ticket_id"],
    "event_id": event["event_id"],
    "original_event_type": original_type,
    "corrected_event_type": event["event_type"],
    "replayed_from": quarantine_queue,
}, separators=(",", ":")))
PY

  wait_for_quarantine_count 0
  wait_for_ticket_status "$(cat "$EVIDENCE_DIR/poison-ticket-id.txt")" processed
  wait_for_main_queue_empty

  echo "QW-004 controlled remediation complete: quarantined payload inspected, corrected, and replayed once without restarting the worker."
}

verify() {
  local poison_ticket_id poison_request_id customer_status
  local failures retries quarantined completions
  local worker_before worker_after api_before api_after
  local ready_status queue_status db_ok redis_ok

  poison_ticket_id=$(cat "$EVIDENCE_DIR/poison-ticket-id.txt")
  poison_request_id=$(cat "$EVIDENCE_DIR/poison-request-id.txt")

  customer_status=$(curl -sS -o "$EVIDENCE_DIR/post-recovery-poison-ticket.json" -w '%{http_code}' \
    -H "X-Customer-ID: $POISON_CUSTOMER" \
    "$API_URL/api/tickets/$poison_ticket_id")
  printf '%s\n' "$customer_status" > "$EVIDENCE_DIR/post-recovery-poison-ticket-http-status.txt"
  if [[ "$customer_status" != "200" ]]; then
    echo "QW-004 recovered poison ticket read failed" >&2
    return 1
  fi

  if [[ "$(ticket_status "$poison_ticket_id")" != "processed" ]]; then
    echo "QW-004 poison ticket did not process after corrected replay" >&2
    return 1
  fi
  printf '%s\n' "$(ticket_status "$poison_ticket_id")" | tee "$EVIDENCE_DIR/post-recovery-poison-processing-status.txt"

  capture_queue_state "$QUEUE_NAME" "$EVIDENCE_DIR/post-recovery-main-queue-state.txt"
  capture_queue_state "$QUARANTINE_QUEUE" "$EVIDENCE_DIR/post-recovery-quarantine-state.txt"

  compose logs --no-color worker > "$EVIDENCE_DIR/post-recovery-worker.log" 2>&1 || true
  failures=$(worker_log_count "$poison_request_id" job_failed)
  retries=$(worker_log_count "$poison_request_id" job_retry_scheduled)
  quarantined=$(worker_log_count "$poison_request_id" job_quarantined)
  completions=$(worker_log_count "$poison_request_id" job_completed)
  printf 'job_failed=%s\njob_retry_scheduled=%s\njob_quarantined=%s\njob_completed=%s\n' \
    "$failures" "$retries" "$quarantined" "$completions" \
    | tee "$EVIDENCE_DIR/post-recovery-poison-outcomes.txt"

  if [[ "$quarantined" != "1" || "$completions" != "1" ]]; then
    echo "QW-004 requires exactly one quarantine and one completion after corrected replay" >&2
    return 1
  fi

  while IFS= read -r ticket_id; do
    if [[ "$(ticket_status "$ticket_id")" != "processed" ]]; then
      echo "QW-004 healthy ticket $ticket_id regressed after poison recovery" >&2
      return 1
    fi
  done < "$EVIDENCE_DIR/healthy-ticket-ids.txt"

  worker_before=$(awk -F= '$1=="worker_container_id" {print $2}' "$EVIDENCE_DIR/baseline-runtime-identity.txt")
  api_before=$(awk -F= '$1=="api_container_id" {print $2}' "$EVIDENCE_DIR/baseline-runtime-identity.txt")
  worker_after=$(compose ps -q worker)
  api_after=$(compose ps -q api)
  printf 'worker_container_before=%s\nworker_container_after=%s\napi_container_before=%s\napi_container_after=%s\n' \
    "$worker_before" "$worker_after" "$api_before" "$api_after" \
    | tee "$EVIDENCE_DIR/post-recovery-runtime-identity.txt"
  if [[ "$worker_before" != "$worker_after" || "$api_before" != "$api_after" ]]; then
    echo "QW-004 recovery must not recreate worker or API containers" >&2
    return 1
  fi

  ready_status=$(curl -sS -o "$EVIDENCE_DIR/post-recovery-readiness.json" -w '%{http_code}' "$API_URL/health/ready")
  queue_status=$(curl -sS -o "$EVIDENCE_DIR/post-recovery-queue-health.json" -w '%{http_code}' "$API_URL/queue-health")
  db_ok=$(psql_cmd -Atc 'SELECT 1;')
  redis_ok=$(compose exec -T redis redis-cli ping)
  printf 'readiness_http=%s\nqueue_health_http=%s\ndb_select_1=%s\nredis_ping=%s\n' \
    "$ready_status" "$queue_status" "$db_ok" "$redis_ok" \
    | tee "$EVIDENCE_DIR/post-recovery-dependency-health.txt"
  if [[ "$ready_status" != "200" || "$queue_status" != "200" || "$db_ok" != "1" || "$redis_ok" != "PONG" ]]; then
    echo "QW-004 dependencies are not healthy after recovery" >&2
    return 1
  fi
  compose exec -T rabbitmq rabbitmq-diagnostics -q ping \
    | tee "$EVIDENCE_DIR/post-recovery-rabbitmq-ping.txt"

  capture_worker_metrics "$EVIDENCE_DIR/post-recovery-worker-metrics.txt"

  echo "QW-004 recovery verified: poison work was bounded and quarantined, healthy work continued, corrected replay completed the affected ticket, and runtime identities stayed unchanged."
}

exercise() {
  baseline
  inject
  diagnose
  recover
  verify
  echo "QW-004 exercise verified: permanently invalid work is bounded, quarantined, inspected, corrected, and replayed without restart, purge, or infinite retry."
}

case "$ACTION" in
  baseline) baseline ;;
  inject) inject ;;
  diagnose) diagnose ;;
  recover) recover ;;
  verify) verify ;;
  exercise) exercise ;;
  *)
    echo "usage: qw_incident_004.sh <baseline|inject|diagnose|recover|verify|exercise>" >&2
    exit 2
    ;;
esac
