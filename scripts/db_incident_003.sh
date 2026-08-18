#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:?usage: db_incident_003.sh <baseline|exercise|diagnose|verify>}"
PROJECT_NAME="${OPSFORGE_PROJECT_NAME:-opsforge-db003}"
POSTGRES_USER="${POSTGRES_USER:-nightwatch}"
POSTGRES_DB="${POSTGRES_DB:-nightwatch}"
EVIDENCE_DIR="${DB003_EVIDENCE_DIR:-$ROOT/.opsforge/evidence/db-003}"
LONGTX_APP="opsforge-db003-idle-transaction"
TARGET_ID="${DB003_TARGET_ID:-84}"
MIN_AGE_SECONDS="${DB003_MIN_AGE_SECONDS:-2}"
CLIENT_PID=""

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

terminate_named_session() {
  psql_cmd -X -Atc "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE application_name = '$LONGTX_APP'
      AND pid <> pg_backend_pid();
  " >/dev/null 2>&1 || true
}

cleanup() {
  terminate_named_session
  if [[ -n "$CLIENT_PID" ]]; then
    wait "$CLIENT_PID" 2>/dev/null || true
  fi
}

baseline() {
  terminate_named_session

  psql_cmd -X -Atc "SELECT count(*) FROM customer_activity WHERE id = $TARGET_ID;" \
    | tee "$EVIDENCE_DIR/baseline-target-count.txt"

  psql_cmd -X -c "
    SET lock_timeout = '2s';
    UPDATE customer_activity SET payload = payload WHERE id = $TARGET_ID;
  " | tee "$EVIDENCE_DIR/baseline-update.txt"

  local stale_count
  stale_count=$(psql_cmd -X -Atc "
    SELECT count(*)
    FROM pg_stat_activity
    WHERE state = 'idle in transaction'
      AND application_name = '$LONGTX_APP';
  ")
  printf '%s\n' "$stale_count" | tee "$EVIDENCE_DIR/baseline-idle-transaction-count.txt"

  if [[ "$stale_count" != "0" ]]; then
    echo "DB-003 baseline unexpectedly contains the simulated long transaction" >&2
    return 1
  fi

  echo "DB-003 baseline verified: no stale simulated transaction and target row is writable."
}

start_idle_transaction() {
  (
    {
      printf 'BEGIN;\n'
      printf 'UPDATE customer_activity SET payload = payload WHERE id = %s;\n' "$TARGET_ID"
      sleep 45
      printf 'ROLLBACK;\n'
    } | compose exec -T -e PGAPPNAME="$LONGTX_APP" db psql \
          -U "$POSTGRES_USER" \
          -d "$POSTGRES_DB" \
          -v ON_ERROR_STOP=1
  ) >"$EVIDENCE_DIR/long-transaction-session.log" 2>&1 &
  CLIENT_PID=$!
}

wait_for_long_transaction() {
  for _ in {1..40}; do
    local count
    count=$(psql_cmd -X -Atc "
      SELECT count(*)
      FROM pg_stat_activity
      WHERE application_name = '$LONGTX_APP'
        AND state = 'idle in transaction'
        AND xact_start IS NOT NULL
        AND clock_timestamp() - xact_start >= make_interval(secs => $MIN_AGE_SECONDS);
    ")
    if [[ "$count" = "1" ]]; then
      return 0
    fi
    sleep 0.5
  done

  echo "DB-003 transaction did not become old enough in idle-in-transaction state" >&2
  return 1
}

capture_diagnostics() {
  psql_cmd -X -P pager=off -c "
    SELECT now() AS observed_at,
           pid,
           application_name,
           state,
           wait_event_type,
           wait_event,
           xact_start,
           age(clock_timestamp(), xact_start) AS transaction_age,
           query_start,
           age(clock_timestamp(), query_start) AS last_query_age,
           backend_xid,
           left(query, 120) AS last_query
    FROM pg_stat_activity
    WHERE application_name = '$LONGTX_APP';
  " | tee "$EVIDENCE_DIR/transaction-activity.txt"

  psql_cmd -X -P pager=off -c "
    SELECT a.pid,
           a.application_name,
           a.state,
           l.locktype,
           l.mode,
           l.granted,
           CASE WHEN l.relation IS NULL THEN NULL ELSE l.relation::regclass::text END AS relation
    FROM pg_stat_activity a
    JOIN pg_locks l ON l.pid = a.pid
    WHERE a.application_name = '$LONGTX_APP'
    ORDER BY l.locktype, l.mode;
  " | tee "$EVIDENCE_DIR/transaction-locks.txt"

  psql_cmd -X -Atc "
    SELECT count(*)
    FROM pg_stat_activity
    WHERE wait_event_type = 'Lock'
      AND cardinality(pg_blocking_pids(pid)) > 0;
  " | tee "$EVIDENCE_DIR/global-blocked-session-count.txt"

  if ! grep -q "$LONGTX_APP" "$EVIDENCE_DIR/transaction-activity.txt"; then
    echo "DB-003 diagnostics did not capture the simulated transaction" >&2
    return 1
  fi
  if ! grep -q "idle in transaction" "$EVIDENCE_DIR/transaction-activity.txt"; then
    echo "DB-003 diagnostics did not prove idle-in-transaction state" >&2
    return 1
  fi
}

diagnose() {
  capture_diagnostics

  local qualifying_count
  qualifying_count=$(psql_cmd -X -Atc "
    SELECT count(*)
    FROM pg_stat_activity
    WHERE application_name = '$LONGTX_APP'
      AND state = 'idle in transaction'
      AND xact_start IS NOT NULL
      AND clock_timestamp() - xact_start >= make_interval(secs => $MIN_AGE_SECONDS);
  ")
  printf '%s\n' "$qualifying_count" | tee "$EVIDENCE_DIR/qualifying-session-count.txt"

  if [[ "$qualifying_count" != "1" ]]; then
    echo "DB-003 expected exactly one qualifying stale transaction, found $qualifying_count" >&2
    return 1
  fi

  echo "DB-003 diagnosis verified: one named stale idle-in-transaction session identified."
}

recover() {
  local target_pid
  target_pid=$(psql_cmd -X -Atc "
    SELECT pid
    FROM pg_stat_activity
    WHERE application_name = '$LONGTX_APP'
      AND state = 'idle in transaction'
      AND xact_start IS NOT NULL
      AND clock_timestamp() - xact_start >= make_interval(secs => $MIN_AGE_SECONDS);
  ")

  if [[ -z "$target_pid" || "$target_pid" == *$'\n'* ]]; then
    echo "DB-003 recovery refused: expected exactly one proven target backend" >&2
    return 1
  fi

  printf 'target_pid=%s\napplication_name=%s\nstate=idle in transaction\nminimum_age_seconds=%s\n' \
    "$target_pid" "$LONGTX_APP" "$MIN_AGE_SECONDS" \
    | tee "$EVIDENCE_DIR/recovery-target.txt"

  psql_cmd -X -Atc "SELECT pg_terminate_backend($target_pid);" \
    | tee "$EVIDENCE_DIR/recovery-action.txt"

  echo "DB-003 approved simulated recovery executed against the evidence-matched backend only."
}

verify() {
  local remaining_count
  remaining_count=$(psql_cmd -X -Atc "
    SELECT count(*)
    FROM pg_stat_activity
    WHERE application_name = '$LONGTX_APP';
  ")
  printf '%s\n' "$remaining_count" | tee "$EVIDENCE_DIR/post-recovery-session-count.txt"
  if [[ "$remaining_count" != "0" ]]; then
    echo "DB-003 recovery left the simulated transaction session alive" >&2
    return 1
  fi

  psql_cmd -X -c "
    SET lock_timeout = '2s';
    UPDATE customer_activity SET payload = payload WHERE id = $TARGET_ID;
  " | tee "$EVIDENCE_DIR/post-recovery-update.txt"

  if ! grep -q "UPDATE 1" "$EVIDENCE_DIR/post-recovery-update.txt"; then
    echo "DB-003 post-recovery write validation failed" >&2
    return 1
  fi

  psql_cmd -X -Atc "SELECT 1;" | tee "$EVIDENCE_DIR/post-recovery-db-health.txt"
  echo "DB-003 recovery verified: stale transaction removed, database reachable, and target row writable."
}

exercise() {
  trap cleanup EXIT
  baseline
  start_idle_transaction
  wait_for_long_transaction
  diagnose
  recover

  if [[ -n "$CLIENT_PID" ]]; then
    wait "$CLIENT_PID" 2>/dev/null || true
    CLIENT_PID=""
  fi

  verify
  echo "DB-003 exercise verified: stale idle transaction identified, targeted, terminated, and recovery proven."
}

case "$ACTION" in
  baseline)
    baseline
    ;;
  exercise)
    exercise
    ;;
  diagnose)
    diagnose
    ;;
  verify)
    verify
    ;;
  *)
    echo "Unsupported action: $ACTION" >&2
    exit 2
    ;;
esac
