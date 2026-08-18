#!/usr/bin/env bash
set -euo pipefail

PROJECT="${OPSFORGE_PROJECT_NAME:-opsforge-db006}"
POSTGRES_USER="${POSTGRES_USER:-nightwatch}"
POSTGRES_DB="${POSTGRES_DB:-nightwatch}"
API_URL="${DB006_API_URL:-http://127.0.0.1:18006}"
EVIDENCE_DIR="${DB006_EVIDENCE_DIR:-.opsforge/evidence/db-006}"
VALIDATION_DB="${DB006_VALIDATION_DB:-nightwatch_restore_validation}"
BACKUP_IN_CONTAINER="/tmp/db006-nightwatch.dump"
BACKUP_FILE="$EVIDENCE_DIR/nightwatch-db006.dump"
SCHEMA_CONTRACT="db/schema-contract.sql"

mkdir -p "$EVIDENCE_DIR"

dc() {
  docker compose -p "$PROJECT" -f docker-compose.yml "$@"
}

psql_db() {
  local database="$1"
  shift
  dc exec -T db psql -U "$POSTGRES_USER" -d "$database" -X -v ON_ERROR_STOP=1 "$@"
}

scalar() {
  local database="$1"
  local query="$2"
  psql_db "$database" -Atc "$query" | tr -d '\r\n'
}

ticket_count() {
  scalar "$1" "SELECT count(*) FROM tickets;"
}

ticket_fingerprint() {
  scalar "$1" "SELECT md5(string_agg(concat_ws('|', id, title, severity, status, processing_status, coalesce(customer_id,''), coalesce(request_id,''), created_at::text, coalesce(processed_at::text,'')), E'\\n' ORDER BY id)) FROM tickets;"
}

activity_count() {
  scalar "$1" "SELECT count(*) FROM customer_activity;"
}

schema_contract() {
  local database="$1"
  psql_db "$database" < "$SCHEMA_CONTRACT"
}

api_code() {
  local path="$1"
  local output="$2"
  curl -sS -o "$output" -w '%{http_code}' "$API_URL$path" 2>/dev/null || true
}

api_ticket_count() {
  python - "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    data = json.load(fh)
if not isinstance(data, list):
    raise SystemExit('ticket API response is not a list')
print(len(data))
PY
}

record_baseline() {
  schema_contract "$POSTGRES_DB" > "$EVIDENCE_DIR/baseline-schema-contract.txt"

  BASELINE_TICKET_COUNT="$(ticket_count "$POSTGRES_DB")"
  BASELINE_TICKET_FINGERPRINT="$(ticket_fingerprint "$POSTGRES_DB")"
  BASELINE_ACTIVITY_COUNT="$(activity_count "$POSTGRES_DB")"

  printf '%s\n' "$BASELINE_TICKET_COUNT" > "$EVIDENCE_DIR/baseline-ticket-count.txt"
  printf '%s\n' "$BASELINE_TICKET_FINGERPRINT" > "$EVIDENCE_DIR/baseline-ticket-fingerprint.txt"
  printf '%s\n' "$BASELINE_ACTIVITY_COUNT" > "$EVIDENCE_DIR/baseline-activity-count.txt"

  local ready_code tickets_code api_count
  ready_code="$(api_code /health/ready "$EVIDENCE_DIR/baseline-readiness.json")"
  tickets_code="$(api_code /api/tickets "$EVIDENCE_DIR/baseline-tickets.json")"
  api_count="$(api_ticket_count "$EVIDENCE_DIR/baseline-tickets.json")"

  printf 'readiness_http=%s\ntickets_http=%s\napi_ticket_count=%s\n' \
    "$ready_code" "$tickets_code" "$api_count" | tee "$EVIDENCE_DIR/baseline-api.txt"

  [[ "$ready_code" = "200" ]]
  [[ "$tickets_code" = "200" ]]
  [[ "$api_count" = "$BASELINE_TICKET_COUNT" ]]
  [[ "$BASELINE_TICKET_COUNT" -ge 3 ]]
  [[ -n "$BASELINE_TICKET_FINGERPRINT" ]]
  [[ "$BASELINE_ACTIVITY_COUNT" = "100000" ]]

  echo "DB-006 baseline verified: schema, customer read path, ticket fingerprint, and activity workload are healthy."
}

create_backup() {
  dc exec -T db sh -lc "rm -f '$BACKUP_IN_CONTAINER' && pg_dump -U '$POSTGRES_USER' -d '$POSTGRES_DB' -Fc --no-owner --no-acl -f '$BACKUP_IN_CONTAINER'"
  dc exec -T db pg_restore --list "$BACKUP_IN_CONTAINER" > "$EVIDENCE_DIR/backup-contents.txt"
  dc cp "db:$BACKUP_IN_CONTAINER" "$BACKUP_FILE" >/dev/null
  sha256sum "$BACKUP_FILE" | tee "$EVIDENCE_DIR/backup-sha256.txt"
  stat -c 'backup_bytes=%s' "$BACKUP_FILE" | tee "$EVIDENCE_DIR/backup-size.txt"
  date -u +'%Y-%m-%dT%H:%M:%SZ' | tee "$EVIDENCE_DIR/backup-created-at.txt"

  [[ -s "$BACKUP_FILE" ]]
  grep -q 'TABLE DATA public tickets' "$EVIDENCE_DIR/backup-contents.txt"
  grep -q 'TABLE DATA public customer_activity' "$EVIDENCE_DIR/backup-contents.txt"

  echo "DB-006 backup created and catalog inspected before any destructive exercise step."
}

validate_backup_restore() {
  psql_db postgres -c "DROP DATABASE IF EXISTS $VALIDATION_DB WITH (FORCE);" > "$EVIDENCE_DIR/validation-drop.txt"
  dc exec -T db createdb -U "$POSTGRES_USER" "$VALIDATION_DB"

  local started ended duration
  started="$(date +%s%3N)"
  dc exec -T db pg_restore -U "$POSTGRES_USER" -d "$VALIDATION_DB" --no-owner --no-acl "$BACKUP_IN_CONTAINER"
  ended="$(date +%s%3N)"
  duration=$((ended - started))
  printf 'validation_restore_duration_ms=%s\n' "$duration" | tee "$EVIDENCE_DIR/validation-restore-duration.txt"

  schema_contract "$VALIDATION_DB" > "$EVIDENCE_DIR/validation-schema-contract.txt"

  local v_count v_fp v_activity
  v_count="$(ticket_count "$VALIDATION_DB")"
  v_fp="$(ticket_fingerprint "$VALIDATION_DB")"
  v_activity="$(activity_count "$VALIDATION_DB")"
  printf 'validation_ticket_count=%s\nvalidation_ticket_fingerprint=%s\nvalidation_activity_count=%s\n' \
    "$v_count" "$v_fp" "$v_activity" | tee "$EVIDENCE_DIR/validation-integrity.txt"

  [[ "$v_count" = "$BASELINE_TICKET_COUNT" ]]
  [[ "$v_fp" = "$BASELINE_TICKET_FINGERPRINT" ]]
  [[ "$v_activity" = "$BASELINE_ACTIVITY_COUNT" ]]

  psql_db postgres -c "DROP DATABASE $VALIDATION_DB WITH (FORCE);" > "$EVIDENCE_DIR/validation-cleanup.txt"
  echo "DB-006 backup validation verified: clean restore matches the baseline before simulated data loss."
}

inject_loss() {
  psql_db "$POSTGRES_DB" -c "TRUNCATE TABLE ticket_events, tickets RESTART IDENTITY CASCADE;" > "$EVIDENCE_DIR/loss-injection.txt"

  local loss_count loss_activity ready_code tickets_code api_count
  loss_count="$(ticket_count "$POSTGRES_DB")"
  loss_activity="$(activity_count "$POSTGRES_DB")"
  ready_code="$(api_code /health/ready "$EVIDENCE_DIR/loss-readiness.json")"
  tickets_code="$(api_code /api/tickets "$EVIDENCE_DIR/loss-tickets.json")"
  api_count="$(api_ticket_count "$EVIDENCE_DIR/loss-tickets.json")"

  printf 'loss_ticket_count=%s\nloss_activity_count=%s\nreadiness_http=%s\ntickets_http=%s\napi_ticket_count=%s\n' \
    "$loss_count" "$loss_activity" "$ready_code" "$tickets_code" "$api_count" | tee "$EVIDENCE_DIR/loss-state.txt"

  [[ "$loss_count" = "0" ]]
  [[ "$api_count" = "0" ]]
  [[ "$loss_activity" = "$BASELINE_ACTIVITY_COUNT" ]]
  [[ "$ready_code" = "200" ]]
  [[ "$tickets_code" = "200" ]]

  echo "DB-006 loss reproduced: PostgreSQL and readiness are healthy, but ticket business data is gone while unrelated activity data remains intact."
}

diagnose_loss() {
  schema_contract "$POSTGRES_DB" > "$EVIDENCE_DIR/loss-schema-contract.txt"
  dc exec -T db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" | tee "$EVIDENCE_DIR/loss-pg-isready.txt"
  psql_db "$POSTGRES_DB" -c "SELECT count(*) AS tickets, (SELECT count(*) FROM customer_activity) AS customer_activity FROM tickets;" \
    > "$EVIDENCE_DIR/loss-database-inventory.txt"

  local expected_hash actual_hash
  expected_hash="$(awk '{print $1}' "$EVIDENCE_DIR/backup-sha256.txt")"
  actual_hash="$(sha256sum "$BACKUP_FILE" | awk '{print $1}')"
  printf 'expected_sha256=%s\nactual_sha256=%s\n' "$expected_hash" "$actual_hash" \
    | tee "$EVIDENCE_DIR/backup-checksum-verification.txt"
  [[ -s "$BACKUP_FILE" ]]
  [[ "$expected_hash" = "$actual_hash" ]]

  echo "DB-006 diagnosis verified: logical ticket-data loss, not database outage or schema loss; validated backup is available for recovery."
}

recover_primary() {
  dc stop api >/dev/null

  psql_db postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$POSTGRES_DB' AND pid <> pg_backend_pid();" \
    > "$EVIDENCE_DIR/recovery-terminated-sessions.txt"
  psql_db postgres -c "DROP DATABASE $POSTGRES_DB;" > "$EVIDENCE_DIR/recovery-drop-primary.txt"
  dc exec -T db createdb -U "$POSTGRES_USER" "$POSTGRES_DB"

  local started ended duration
  started="$(date +%s%3N)"
  dc exec -T db pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-acl "$BACKUP_IN_CONTAINER"
  ended="$(date +%s%3N)"
  duration=$((ended - started))
  printf 'primary_restore_duration_ms=%s\n' "$duration" | tee "$EVIDENCE_DIR/primary-restore-duration.txt"

  dc start api >/dev/null
  local recovered=0
  for attempt in {1..40}; do
    if [[ "$(api_code /health/ready "$EVIDENCE_DIR/recovery-readiness.json")" = "200" ]]; then
      recovered=1
      break
    fi
    sleep 1
  done
  [[ "$recovered" = "1" ]]

  echo "DB-006 approved simulated restore completed from the previously validated backup."
}

verify_recovery() {
  schema_contract "$POSTGRES_DB" > "$EVIDENCE_DIR/final-schema-contract.txt"

  local final_count final_fp final_activity ready_code tickets_code api_count write_probe_count
  final_count="$(ticket_count "$POSTGRES_DB")"
  final_fp="$(ticket_fingerprint "$POSTGRES_DB")"
  final_activity="$(activity_count "$POSTGRES_DB")"
  ready_code="$(api_code /health/ready "$EVIDENCE_DIR/final-readiness.json")"
  tickets_code="$(api_code /api/tickets "$EVIDENCE_DIR/final-tickets.json")"
  api_count="$(api_ticket_count "$EVIDENCE_DIR/final-tickets.json")"

  psql_db "$POSTGRES_DB" -qAtc "BEGIN; INSERT INTO tickets (title,severity,status,processing_status,customer_id) VALUES ('db006-write-probe','SEV4','Open','seeded','db006'); ROLLBACK;" \
    > "$EVIDENCE_DIR/post-restore-write-probe.txt"
  write_probe_count="$(ticket_count "$POSTGRES_DB")"

  printf 'baseline_ticket_count=%s\nfinal_ticket_count=%s\nbaseline_ticket_fingerprint=%s\nfinal_ticket_fingerprint=%s\nbaseline_activity_count=%s\nfinal_activity_count=%s\nreadiness_http=%s\ntickets_http=%s\napi_ticket_count=%s\npost_restore_write_probe_count=%s\n' \
    "$BASELINE_TICKET_COUNT" "$final_count" "$BASELINE_TICKET_FINGERPRINT" "$final_fp" \
    "$BASELINE_ACTIVITY_COUNT" "$final_activity" "$ready_code" "$tickets_code" "$api_count" "$write_probe_count" \
    | tee "$EVIDENCE_DIR/final-integrity.txt"

  [[ "$final_count" = "$BASELINE_TICKET_COUNT" ]]
  [[ "$final_fp" = "$BASELINE_TICKET_FINGERPRINT" ]]
  [[ "$final_activity" = "$BASELINE_ACTIVITY_COUNT" ]]
  [[ "$ready_code" = "200" ]]
  [[ "$tickets_code" = "200" ]]
  [[ "$api_count" = "$BASELINE_TICKET_COUNT" ]]
  [[ "$write_probe_count" = "$BASELINE_TICKET_COUNT" ]]
  [[ "$(ticket_fingerprint "$POSTGRES_DB")" = "$BASELINE_TICKET_FINGERPRINT" ]]

  dc exec -T db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" | tee "$EVIDENCE_DIR/final-pg-isready.txt"
  echo "DB-006 recovery verified: schema, ticket data, activity workload, customer read path, and transactional write capability match the pre-loss baseline."
}

exercise() {
  record_baseline
  create_backup
  validate_backup_restore
  inject_loss
  diagnose_loss
  recover_primary
  verify_recovery
  echo "DB-006 exercise verified: backup validated before loss, logical data loss proven, primary restored, and application/data integrity re-established."
}

case "${1:-exercise}" in
  baseline) record_baseline ;;
  backup) record_baseline; create_backup ;;
  validate) record_baseline; create_backup; validate_backup_restore ;;
  inject) record_baseline; create_backup; validate_backup_restore; inject_loss ;;
  diagnose) record_baseline; create_backup; validate_backup_restore; inject_loss; diagnose_loss ;;
  recover) record_baseline; create_backup; validate_backup_restore; inject_loss; diagnose_loss; recover_primary ;;
  verify|exercise) exercise ;;
  *) echo "usage: $0 {baseline|backup|validate|inject|diagnose|recover|verify|exercise}" >&2; exit 2 ;;
esac
