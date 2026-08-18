#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:?usage: db_incident_005.sh <baseline|inject|diagnose|recover|verify|exercise>}"
PROJECT_NAME="${OPSFORGE_PROJECT_NAME:-opsforge-db005}"
POSTGRES_USER="${POSTGRES_USER:-nightwatch}"
POSTGRES_DB="${POSTGRES_DB:-nightwatch}"
API_URL="${DB005_API_URL:-http://127.0.0.1:${API_HOST_PORT:-18005}}"
EVIDENCE_DIR="${DB005_EVIDENCE_DIR:-$ROOT/.opsforge/evidence/db-005}"
FORWARD_MIGRATION="$ROOT/db/incidents/db005-forward.sql"
ROLLBACK_MIGRATION="$ROOT/db/incidents/db005-rollback.sql"

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

http_status() {
  local path="$1"
  local output="$2"
  curl -sS -o "$output" -w '%{http_code}' "$API_URL$path"
}

column_exists() {
  local column="$1"
  psql_cmd -Atc "
    SELECT count(*)
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'tickets'
      AND column_name = '$column';
  "
}

ticket_count() {
  psql_cmd -Atc "SELECT count(*) FROM tickets;"
}

ticket_fingerprint() {
  local state_column="$1"
  psql_cmd -Atc "
    SELECT md5(COALESCE(string_agg(
      concat_ws('|',
        id::text,
        title,
        severity,
        status,
        $state_column,
        COALESCE(customer_id, ''),
        COALESCE(request_id, ''),
        COALESCE(created_at::text, ''),
        COALESCE(processed_at::text, '')
      ), E'\\n' ORDER BY id
    ), ''))
    FROM tickets;
  "
}

run_schema_contract() {
  psql_cmd < "$ROOT/db/schema-contract.sql"
}

baseline() {
  local processing_exists job_state_exists ready_status tickets_status count fingerprint

  processing_exists=$(column_exists processing_status)
  job_state_exists=$(column_exists job_state)
  printf 'processing_status=%s\njob_state=%s\n' "$processing_exists" "$job_state_exists" \
    | tee "$EVIDENCE_DIR/baseline-columns.txt"

  if [[ "$processing_exists" != "1" || "$job_state_exists" != "0" ]]; then
    echo "DB-005 baseline schema is not the expected application-compatible state" >&2
    return 1
  fi

  run_schema_contract >"$EVIDENCE_DIR/baseline-schema-contract.txt" 2>&1

  ready_status=$(http_status /health/ready "$EVIDENCE_DIR/baseline-readiness.json")
  tickets_status=$(http_status /api/tickets "$EVIDENCE_DIR/baseline-tickets.json")
  printf 'readiness_http=%s\ntickets_http=%s\n' "$ready_status" "$tickets_status" \
    | tee "$EVIDENCE_DIR/baseline-http-status.txt"

  if [[ "$ready_status" != "200" || "$tickets_status" != "200" ]]; then
    echo "DB-005 baseline requires healthy readiness and ticket API" >&2
    return 1
  fi

  count=$(ticket_count)
  fingerprint=$(ticket_fingerprint processing_status)
  printf '%s\n' "$count" > "$EVIDENCE_DIR/baseline-ticket-count.txt"
  printf '%s\n' "$fingerprint" > "$EVIDENCE_DIR/baseline-ticket-fingerprint.txt"

  psql_cmd -Atc "SELECT 1;" | tee "$EVIDENCE_DIR/baseline-db-health.txt"
  echo "DB-005 baseline verified: schema contract, readiness, customer query, and data fingerprint are healthy."
}

inject() {
  psql_cmd < "$FORWARD_MIGRATION" | tee "$EVIDENCE_DIR/forward-migration.txt"

  local processing_exists job_state_exists
  processing_exists=$(column_exists processing_status)
  job_state_exists=$(column_exists job_state)
  printf 'processing_status=%s\njob_state=%s\n' "$processing_exists" "$job_state_exists" \
    | tee "$EVIDENCE_DIR/post-migration-columns.txt"

  if [[ "$processing_exists" != "0" || "$job_state_exists" != "1" ]]; then
    echo "DB-005 forward migration did not create the expected incompatible schema" >&2
    return 1
  fi

  echo "DB-005 incompatible migration applied: data preserved but the deployed application column contract changed."
}

diagnose() {
  local ready_status tickets_status contract_rc before_count current_count before_fingerprint current_fingerprint

  psql_cmd -Atc "SELECT 1;" | tee "$EVIDENCE_DIR/incident-db-health.txt"

  ready_status=$(http_status /health/ready "$EVIDENCE_DIR/incident-readiness.json")
  tickets_status=$(http_status /api/tickets "$EVIDENCE_DIR/incident-tickets-response.txt")
  printf 'readiness_http=%s\ntickets_http=%s\n' "$ready_status" "$tickets_status" \
    | tee "$EVIDENCE_DIR/incident-http-status.txt"

  if [[ "$ready_status" != "200" ]]; then
    echo "DB-005 expected readiness to remain green while schema compatibility was broken" >&2
    return 1
  fi
  if [[ "$tickets_status" != "500" ]]; then
    echo "DB-005 expected /api/tickets to fail with HTTP 500 after incompatible migration" >&2
    return 1
  fi

  set +e
  run_schema_contract >"$EVIDENCE_DIR/incident-schema-contract.txt" 2>&1
  contract_rc=$?
  set -e
  printf '%s\n' "$contract_rc" > "$EVIDENCE_DIR/incident-schema-contract-exit-code.txt"

  if [[ "$contract_rc" -eq 0 ]]; then
    echo "DB-005 schema contract unexpectedly passed after incompatible migration" >&2
    return 1
  fi
  if ! grep -qi "processing_status" "$EVIDENCE_DIR/incident-schema-contract.txt"; then
    echo "DB-005 schema-contract failure did not identify the missing application column" >&2
    return 1
  fi

  psql_cmd -P pager=off -c "
    SELECT ordinal_position, column_name, data_type, is_nullable
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'tickets'
    ORDER BY ordinal_position;
  " | tee "$EVIDENCE_DIR/incident-ticket-schema.txt"

  compose logs --no-color api > "$EVIDENCE_DIR/incident-api.log" 2>&1 || true
  if ! grep -qi "processing_status" "$EVIDENCE_DIR/incident-api.log"; then
    echo "DB-005 API logs did not contain the broken column contract evidence" >&2
    return 1
  fi

  before_count=$(cat "$EVIDENCE_DIR/baseline-ticket-count.txt")
  before_fingerprint=$(cat "$EVIDENCE_DIR/baseline-ticket-fingerprint.txt")
  current_count=$(ticket_count)
  current_fingerprint=$(ticket_fingerprint job_state)
  printf 'baseline_count=%s\nincident_count=%s\nbaseline_fingerprint=%s\nincident_fingerprint=%s\n' \
    "$before_count" "$current_count" "$before_fingerprint" "$current_fingerprint" \
    | tee "$EVIDENCE_DIR/incident-data-integrity.txt"

  if [[ "$before_count" != "$current_count" || "$before_fingerprint" != "$current_fingerprint" ]]; then
    echo "DB-005 migration changed ticket data; automatic rollback exercise is no longer safe" >&2
    return 1
  fi

  echo "DB-005 diagnosis verified: PostgreSQL/readiness stayed healthy, customer query failed, schema contract identified the mismatch, and ticket data remained unchanged."
}

recover() {
  local before_count current_count before_fingerprint current_fingerprint

  before_count=$(cat "$EVIDENCE_DIR/baseline-ticket-count.txt")
  before_fingerprint=$(cat "$EVIDENCE_DIR/baseline-ticket-fingerprint.txt")
  current_count=$(ticket_count)
  current_fingerprint=$(ticket_fingerprint job_state)

  if [[ "$before_count" != "$current_count" || "$before_fingerprint" != "$current_fingerprint" ]]; then
    echo "DB-005 rollback refused: data integrity no longer matches the pre-migration fingerprint" >&2
    return 1
  fi

  psql_cmd < "$ROLLBACK_MIGRATION" | tee "$EVIDENCE_DIR/rollback-migration.txt"
  echo "DB-005 approved simulated rollback executed after proving the migration was metadata-only and data-preserving."
}

verify() {
  local processing_exists job_state_exists ready_status tickets_status before_count final_count before_fingerprint final_fingerprint

  processing_exists=$(column_exists processing_status)
  job_state_exists=$(column_exists job_state)
  printf 'processing_status=%s\njob_state=%s\n' "$processing_exists" "$job_state_exists" \
    | tee "$EVIDENCE_DIR/post-recovery-columns.txt"
  if [[ "$processing_exists" != "1" || "$job_state_exists" != "0" ]]; then
    echo "DB-005 rollback did not restore the application schema contract" >&2
    return 1
  fi

  run_schema_contract >"$EVIDENCE_DIR/post-recovery-schema-contract.txt" 2>&1

  ready_status=$(http_status /health/ready "$EVIDENCE_DIR/post-recovery-readiness.json")
  tickets_status=$(http_status /api/tickets "$EVIDENCE_DIR/post-recovery-tickets.json")
  printf 'readiness_http=%s\ntickets_http=%s\n' "$ready_status" "$tickets_status" \
    | tee "$EVIDENCE_DIR/post-recovery-http-status.txt"
  if [[ "$ready_status" != "200" || "$tickets_status" != "200" ]]; then
    echo "DB-005 post-recovery application verification failed" >&2
    return 1
  fi

  before_count=$(cat "$EVIDENCE_DIR/baseline-ticket-count.txt")
  before_fingerprint=$(cat "$EVIDENCE_DIR/baseline-ticket-fingerprint.txt")
  final_count=$(ticket_count)
  final_fingerprint=$(ticket_fingerprint processing_status)
  printf 'baseline_count=%s\nfinal_count=%s\nbaseline_fingerprint=%s\nfinal_fingerprint=%s\n' \
    "$before_count" "$final_count" "$before_fingerprint" "$final_fingerprint" \
    | tee "$EVIDENCE_DIR/post-recovery-data-integrity.txt"

  if [[ "$before_count" != "$final_count" || "$before_fingerprint" != "$final_fingerprint" ]]; then
    echo "DB-005 post-recovery data integrity does not match the baseline" >&2
    return 1
  fi

  psql_cmd -Atc "SELECT 1;" | tee "$EVIDENCE_DIR/post-recovery-db-health.txt"
  echo "DB-005 recovery verified: schema contract restored, ticket API recovered, and ticket data fingerprint is unchanged."
}

exercise() {
  baseline
  inject
  diagnose
  recover
  verify
  echo "DB-005 exercise verified: incompatible migration identified as schema-version mismatch, safely rolled back, and data/application recovery proven."
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
