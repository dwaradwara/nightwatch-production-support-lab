#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_env.sh"

RELEASE="${1:?usage: app_incident_004.sh <release>}"
EVIDENCE_DIR="${APP004_EVIDENCE_DIR:-$ROOT/.opsforge/evidence/app-004}"
CUSTOMER_ID="app004-customer"
API_CONTAINER="nightwatch-staging-api"
CPU_NANO_LIMIT="250000000"
BURNER_COUNT="12"
BURNER_NAME="opsforge_app004_cpu_burn.py"

load_opsforge_secrets
configure_opsforge_environment staging
export RELEASE_VERSION="$RELEASE"
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

cpu_stat_value() {
  local key="$1"
  docker exec "$API_CONTAINER" sh -c "awk '\$1 == \"$key\" {print \$2}' /sys/fs/cgroup/cpu.stat"
}

capture_cpu_stat() {
  local file="$1"
  docker exec "$API_CONTAINER" cat /sys/fs/cgroup/cpu.stat > "$file"
}

measure_ticket_reads() {
  local label="$1"
  local samples_file="$EVIDENCE_DIR/${label}-latencies.txt"
  local summary_file="$EVIDENCE_DIR/${label}-latency-summary.txt"
  : > "$samples_file"

  for sample in $(seq 1 25); do
    result=$(curl -sS -o /dev/null -w '%{http_code}|%{time_total}' \
      -H "X-Customer-ID: $CUSTOMER_ID" "$BASE_URL/api/tickets/$TICKET_ID")
    printf '%s\n' "$result" >> "$samples_file"
    [[ "${result%%|*}" = "200" ]]
  done

  python - "$samples_file" "$summary_file" <<'PY'
import math
import statistics
import sys

samples = []
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        code, seconds = line.strip().split("|", 1)
        if code != "200":
            raise SystemExit(f"unexpected HTTP status {code}")
        samples.append(float(seconds))

ordered = sorted(samples)
p95 = ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)]
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    handle.write(f"count={len(samples)}\n")
    handle.write(f"min_seconds={min(samples):.6f}\n")
    handle.write(f"median_seconds={statistics.median(samples):.6f}\n")
    handle.write(f"p95_seconds={p95:.6f}\n")
    handle.write(f"max_seconds={max(samples):.6f}\n")
PY
}

kill_burners() {
  docker exec -i "$API_CONTAINER" python - <<'PY'
import os
import signal

needle = b"opsforge_app004_cpu_burn.py"
self_pid = os.getpid()
killed = []
for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    pid = int(entry)
    if pid in (1, self_pid):
        continue
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            cmdline = handle.read()
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        continue
    if needle in cmdline:
        try:
            os.kill(pid, signal.SIGTERM)
            killed.append(pid)
        except ProcessLookupError:
            pass
print("killed=" + ",".join(map(str, killed)))
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
import json
import os
try:
    payload = json.loads(os.environ["LOKI_JSON"])
except json.JSONDecodeError:
    raise SystemExit(1)
raise SystemExit(0 if payload.get("data", {}).get("result") else 1)
PY
    then return 0; fi
    sleep 2
  done
  return 1
}

echo "APP-004: deploying normal release $RELEASE"
bash "$ROOT/scripts/deploy_release.sh" staging "$RELEASE"
wait_ready

# Establish one fixed resource budget before the healthy baseline. The budget is
# intentionally retained through failure and recovery so the incident is caused
# by CPU contention, not by changing the quota during the fault window.
docker update --cpus 0.25 "$API_CONTAINER" >/dev/null
sleep 2
wait_ready

curl -fsS "$BASE_URL/version" > "$EVIDENCE_DIR/version-before.json"
grep -q "\"version\":\"$RELEASE\"" "$EVIDENCE_DIR/version-before.json"
BASE_CONTAINER_ID=$(docker inspect -f '{{.Id}}' "$API_CONTAINER")
BASE_IMAGE_ID=$(docker inspect -f '{{.Image}}' "$API_CONTAINER")
BASE_PID=$(docker inspect -f '{{.State.Pid}}' "$API_CONTAINER")
BASE_NANO_CPUS=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$API_CONTAINER")
[[ "$BASE_NANO_CPUS" = "$CPU_NANO_LIMIT" ]]
printf '%s\n' "$BASE_CONTAINER_ID" > "$EVIDENCE_DIR/api-container-before.txt"
printf '%s\n' "$BASE_IMAGE_ID" > "$EVIDENCE_DIR/api-image-before.txt"
printf '%s\n' "$BASE_PID" > "$EVIDENCE_DIR/api-pid-before.txt"
printf '%s\n' "$BASE_NANO_CPUS" > "$EVIDENCE_DIR/api-nanocpus.txt"

create_code=$(curl -sS -o "$EVIDENCE_DIR/create.json" -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -H "X-Customer-ID: $CUSTOMER_ID" \
  -d '{"title":"APP-004 CPU saturation probe","severity":"SEV2"}' \
  "$BASE_URL/api/tickets")
[[ "$create_code" = "201" ]]
TICKET_ID=$(python -c 'import json; print(json.load(open("'"$EVIDENCE_DIR"'/create.json"))["id"])')

baseline_code=$(curl -sS -o "$EVIDENCE_DIR/baseline-ticket.json" -w '%{http_code}' \
  -H "X-Customer-ID: $CUSTOMER_ID" "$BASE_URL/api/tickets/$TICKET_ID")
[[ "$baseline_code" = "200" ]]
measure_ticket_reads baseline
BASELINE_P95=$(awk -F= '/^p95_seconds=/ {print $2}' "$EVIDENCE_DIR/baseline-latency-summary.txt")
capture_cpu_stat "$EVIDENCE_DIR/cpu-stat-before.txt"
BASE_NR_THROTTLED=$(cpu_stat_value nr_throttled)
BASE_THROTTLED_USEC=$(cpu_stat_value throttled_usec)

cat > "$EVIDENCE_DIR/$BURNER_NAME" <<'PY'
value = 0
while True:
    value = (value + 1) % 1000003
PY
docker cp "$EVIDENCE_DIR/$BURNER_NAME" "$API_CONTAINER:/tmp/$BURNER_NAME"

echo "APP-004: injecting sustained CPU contention with $BURNER_COUNT runaway processes"
for burner in $(seq 1 "$BURNER_COUNT"); do
  docker exec -d "$API_CONTAINER" python "/tmp/$BURNER_NAME"
done
sleep 4

docker top "$API_CONTAINER" -eo pid,args > "$EVIDENCE_DIR/docker-top-degraded.txt"
grep -F "$BURNER_NAME" "$EVIDENCE_DIR/docker-top-degraded.txt" >/dev/null

DEGRADED_CONTAINER_ID=$(docker inspect -f '{{.Id}}' "$API_CONTAINER")
DEGRADED_IMAGE_ID=$(docker inspect -f '{{.Image}}' "$API_CONTAINER")
DEGRADED_PID=$(docker inspect -f '{{.State.Pid}}' "$API_CONTAINER")
DEGRADED_NANO_CPUS=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$API_CONTAINER")
[[ "$DEGRADED_CONTAINER_ID" = "$BASE_CONTAINER_ID" ]]
[[ "$DEGRADED_IMAGE_ID" = "$BASE_IMAGE_ID" ]]
[[ "$DEGRADED_PID" = "$BASE_PID" ]]
[[ "$DEGRADED_NANO_CPUS" = "$CPU_NANO_LIMIT" ]]

for endpoint in health/ready db-health cache-health queue-health; do
  safe_name=${endpoint//\//-}
  code=$(curl -sS -o "$EVIDENCE_DIR/$safe_name.json" -w '%{http_code}' "$BASE_URL/$endpoint")
  [[ "$code" = "200" ]]
done

docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$API_CONTAINER" > "$EVIDENCE_DIR/api-health-degraded.txt"
grep -q '^healthy$' "$EVIDENCE_DIR/api-health-degraded.txt"

measure_ticket_reads degraded
DEGRADED_P95=$(awk -F= '/^p95_seconds=/ {print $2}' "$EVIDENCE_DIR/degraded-latency-summary.txt")
capture_cpu_stat "$EVIDENCE_DIR/cpu-stat-degraded.txt"
DEGRADED_NR_THROTTLED=$(cpu_stat_value nr_throttled)
DEGRADED_THROTTLED_USEC=$(cpu_stat_value throttled_usec)
NR_THROTTLED_DELTA=$((DEGRADED_NR_THROTTLED - BASE_NR_THROTTLED))
THROTTLED_USEC_DELTA=$((DEGRADED_THROTTLED_USEC - BASE_THROTTLED_USEC))

BASELINE_P95="$BASELINE_P95" DEGRADED_P95="$DEGRADED_P95" python - <<'PY'
import os
baseline = float(os.environ["BASELINE_P95"])
degraded = float(os.environ["DEGRADED_P95"])
if degraded < 0.04:
    raise SystemExit(f"degraded p95 too small to prove customer-visible latency: {degraded}")
if degraded < baseline * 1.5:
    raise SystemExit(f"degraded p95 did not increase enough: baseline={baseline} degraded={degraded}")
PY
(( NR_THROTTLED_DELTA >= 5 ))
(( THROTTLED_USEC_DELTA >= 500000 ))

probe_result=$(curl -sS -D "$EVIDENCE_DIR/degraded-probe-headers.txt" -o "$EVIDENCE_DIR/degraded-probe-body.json" \
  -w '%{http_code}|%{time_total}' -H "X-Customer-ID: $CUSTOMER_ID" "$BASE_URL/api/tickets/$TICKET_ID")
IFS='|' read -r PROBE_CODE PROBE_SECONDS <<< "$probe_result"
[[ "$PROBE_CODE" = "200" ]]
REQUEST_ID=$(awk 'BEGIN{IGNORECASE=1} /^X-Request-ID:/ {gsub("\r", "", $2); print $2}' "$EVIDENCE_DIR/degraded-probe-headers.txt")
test -n "$REQUEST_ID"

opsforge_compose logs --no-color --tail=320 nginx > "$EVIDENCE_DIR/nginx.log" 2>&1
opsforge_compose logs --no-color --tail=320 api > "$EVIDENCE_DIR/api.log" 2>&1
grep -F "$REQUEST_ID" "$EVIDENCE_DIR/nginx.log" >/dev/null
grep -F "$REQUEST_ID" "$EVIDENCE_DIR/api.log" >/dev/null
wait_tempo "$REQUEST_ID"
wait_loki "$REQUEST_ID"

cat > "$EVIDENCE_DIR/diagnosis.txt" <<EOF
customer_read_http=200
customer_probe_seconds=$PROBE_SECONDS
baseline_p95_seconds=$BASELINE_P95
degraded_p95_seconds=$DEGRADED_P95
request_id=$REQUEST_ID
ticket_id=$TICKET_ID
release=$RELEASE
api_cpu_nanocpus=$CPU_NANO_LIMIT
runaway_processes=$BURNER_COUNT
api_container_id=$BASE_CONTAINER_ID
api_container_unchanged=true
api_image_id=$BASE_IMAGE_ID
api_image_unchanged=true
api_pid=$BASE_PID
api_pid_unchanged=true
postgresql=healthy
redis=healthy
rabbitmq=healthy
api_health=healthy
nr_throttled_delta=$NR_THROTTLED_DELTA
throttled_usec_delta=$THROTTLED_USEC_DELTA
nginx_request_correlated=true
api_request_correlated=true
tempo_correlated=true
loki_correlated=true
assessment=customer latency degradation is caused by CPU contention and cgroup throttling inside the unchanged API runtime
EOF

echo "APP-004 diagnosis proven: API CPU contention degraded latency while process, image, readiness, and dependencies stayed healthy."

echo "APP-004: terminating only the runaway CPU workload"
kill_burners > "$EVIDENCE_DIR/burner-termination.txt"
sleep 3
docker top "$API_CONTAINER" -eo pid,args > "$EVIDENCE_DIR/docker-top-recovered.txt"
if grep -F "$BURNER_NAME" "$EVIDENCE_DIR/docker-top-recovered.txt" >/dev/null; then
  echo "APP-004 burner process still present after targeted termination" >&2
  exit 1
fi

RECOVERED_CONTAINER_ID=$(docker inspect -f '{{.Id}}' "$API_CONTAINER")
RECOVERED_IMAGE_ID=$(docker inspect -f '{{.Image}}' "$API_CONTAINER")
RECOVERED_PID=$(docker inspect -f '{{.State.Pid}}' "$API_CONTAINER")
RECOVERED_NANO_CPUS=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$API_CONTAINER")
[[ "$RECOVERED_CONTAINER_ID" = "$BASE_CONTAINER_ID" ]]
[[ "$RECOVERED_IMAGE_ID" = "$BASE_IMAGE_ID" ]]
[[ "$RECOVERED_PID" = "$BASE_PID" ]]
[[ "$RECOVERED_NANO_CPUS" = "$CPU_NANO_LIMIT" ]]

RECOVERY_START_THROTTLED=$(cpu_stat_value throttled_usec)
sleep 3
RECOVERY_END_THROTTLED=$(cpu_stat_value throttled_usec)
RECOVERY_THROTTLED_DELTA=$((RECOVERY_END_THROTTLED - RECOVERY_START_THROTTLED))

measure_ticket_reads recovered
RECOVERED_P95=$(awk -F= '/^p95_seconds=/ {print $2}' "$EVIDENCE_DIR/recovered-latency-summary.txt")
DEGRADED_P95="$DEGRADED_P95" RECOVERED_P95="$RECOVERED_P95" python - <<'PY'
import os
degraded = float(os.environ["DEGRADED_P95"])
recovered = float(os.environ["RECOVERED_P95"])
if recovered >= degraded * 0.8:
    raise SystemExit(f"latency did not recover enough: degraded={degraded} recovered={recovered}")
PY
(( RECOVERY_THROTTLED_DELTA < THROTTLED_USEC_DELTA ))

recovery_code=$(curl -sS -o "$EVIDENCE_DIR/recovered-ticket.json" -w '%{http_code}' \
  -H "X-Customer-ID: $CUSTOMER_ID" "$BASE_URL/api/tickets/$TICKET_ID")
[[ "$recovery_code" = "200" ]]
wait_ready
curl -fsS "$BASE_URL/version" > "$EVIDENCE_DIR/version-recovered.json"
grep -q "\"version\":\"$RELEASE\"" "$EVIDENCE_DIR/version-recovered.json"
bash "$ROOT/scripts/verify_release.sh" staging "$RELEASE"

cat > "$EVIDENCE_DIR/recovery.txt" <<EOF
recovered_release=$RELEASE
recovered_p95_seconds=$RECOVERED_P95
recovered_api_container_id=$RECOVERED_CONTAINER_ID
recovered_api_image_id=$RECOVERED_IMAGE_ID
recovered_api_pid=$RECOVERED_PID
api_container_unchanged=true
api_image_unchanged=true
api_pid_unchanged=true
api_cpu_nanocpus_unchanged=true
runaway_processes_terminated=true
api_restart_required=false
application_redeploy_required=false
resource_limit_change_required=false
original_ticket_http=200
recovery_throttled_usec_delta=$RECOVERY_THROTTLED_DELTA
full_customer_journey_verified=true
EOF

echo "APP-004 recovery verified: targeted workload termination restores latency without restarting or redeploying the API."
