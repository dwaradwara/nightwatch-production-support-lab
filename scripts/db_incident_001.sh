#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:?usage: db_incident_001.sh <baseline|inject|diagnose|recover|verify>}"
CUSTOMER_ID="${DB001_CUSTOMER_ID:-customer-0042}"
PROJECT_NAME="${OPSFORGE_PROJECT_NAME:-opsforge-db001}"
POSTGRES_USER="${POSTGRES_USER:-nightwatch}"
POSTGRES_DB="${POSTGRES_DB:-nightwatch}"
EVIDENCE_DIR="${DB001_EVIDENCE_DIR:-$ROOT/.opsforge/evidence/db-001}"
INDEX_NAME="idx_customer_activity_customer_time"

mkdir -p "$EVIDENCE_DIR"

compose() {
  docker compose -p "$PROJECT_NAME" -f "$ROOT/docker-compose.yml" "$@"
}

psql_cmd() {
  compose exec -T db psql \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 \
    "$@"
}

capture_plan() {
  local output_file="${1:?output file required}"
  psql_cmd -X -P pager=off -c "
    EXPLAIN (ANALYZE, BUFFERS)
    SELECT id, event_type, payload, occurred_at
    FROM customer_activity
    WHERE customer_id = '$CUSTOMER_ID'
    ORDER BY occurred_at DESC
    LIMIT 20;
  " | tee "$output_file"
}

assert_index_plan() {
  local plan_file="${1:?plan file required}"
  if ! grep -q "$INDEX_NAME" "$plan_file"; then
    echo "Expected query plan to use $INDEX_NAME" >&2
    exit 1
  fi
}

assert_seq_scan_plan() {
  local plan_file="${1:?plan file required}"
  if ! grep -q "Seq Scan on customer_activity" "$plan_file"; then
    echo "Expected incident query plan to contain a sequential scan" >&2
    exit 1
  fi
  if grep -q "$INDEX_NAME" "$plan_file"; then
    echo "Incident plan unexpectedly still references $INDEX_NAME" >&2
    exit 1
  fi
}

case "$ACTION" in
  baseline)
    psql_cmd -X -Atc "SELECT count(*) FROM customer_activity;" \
      | tee "$EVIDENCE_DIR/row-count.txt"
    psql_cmd -X -Atc "SELECT indexname FROM pg_indexes WHERE tablename='customer_activity' ORDER BY indexname;" \
      | tee "$EVIDENCE_DIR/baseline-indexes.txt"
    capture_plan "$EVIDENCE_DIR/baseline-plan.txt"
    assert_index_plan "$EVIDENCE_DIR/baseline-plan.txt"
    echo "DB-001 baseline verified: indexed customer activity lookup."
    ;;

  inject)
    psql_cmd -X -c "DROP INDEX IF EXISTS $INDEX_NAME; ANALYZE customer_activity;"
    echo "DB-001 injected: $INDEX_NAME removed."
    ;;

  diagnose)
    psql_cmd -X -P pager=off -c "
      SELECT now() AS observed_at,
             current_database() AS database,
             pg_size_pretty(pg_total_relation_size('customer_activity')) AS activity_relation_size;
      SELECT indexname, indexdef
      FROM pg_indexes
      WHERE tablename = 'customer_activity'
      ORDER BY indexname;
      SELECT pid, state, wait_event_type, wait_event,
             left(query, 120) AS query
      FROM pg_stat_activity
      WHERE datname = current_database()
      ORDER BY pid;
    " | tee "$EVIDENCE_DIR/diagnostics.txt"
    capture_plan "$EVIDENCE_DIR/incident-plan.txt"
    assert_seq_scan_plan "$EVIDENCE_DIR/incident-plan.txt"
    echo "DB-001 diagnosis verified: customer lookup regressed to sequential scan."
    ;;

  recover)
    psql_cmd -X -c "
      CREATE INDEX CONCURRENTLY IF NOT EXISTS $INDEX_NAME
      ON customer_activity (customer_id, occurred_at DESC);
    "
    psql_cmd -X -c "ANALYZE customer_activity;"
    echo "DB-001 recovery applied: $INDEX_NAME restored."
    ;;

  verify)
    psql_cmd -X -Atc "SELECT indexname FROM pg_indexes WHERE tablename='customer_activity' ORDER BY indexname;" \
      | tee "$EVIDENCE_DIR/recovered-indexes.txt"
    capture_plan "$EVIDENCE_DIR/recovered-plan.txt"
    assert_index_plan "$EVIDENCE_DIR/recovered-plan.txt"
    ROWS=$(psql_cmd -X -Atc "
      SELECT count(*)
      FROM (
        SELECT id
        FROM customer_activity
        WHERE customer_id = '$CUSTOMER_ID'
        ORDER BY occurred_at DESC
        LIMIT 20
      ) q;
    ")
    if [[ "$ROWS" != "20" ]]; then
      echo "Expected 20 customer activity rows after recovery, got $ROWS" >&2
      exit 1
    fi
    printf '%s\n' "$ROWS" | tee "$EVIDENCE_DIR/recovered-result-count.txt"
    echo "DB-001 recovery verified: indexed plan restored and customer query returns expected data."
    ;;

  *)
    echo "Unsupported action: $ACTION" >&2
    exit 2
    ;;
esac
