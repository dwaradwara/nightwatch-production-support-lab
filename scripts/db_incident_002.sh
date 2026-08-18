#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:?usage: db_incident_002.sh <baseline|exercise|diagnose|verify>}"
PROJECT_NAME="${OPSFORGE_PROJECT_NAME:-opsforge-db002}"
POSTGRES_USER="${POSTGRES_USER:-nightwatch}"
POSTGRES_DB="${POSTGRES_DB:-nightwatch}"
EVIDENCE_DIR="${DB002_EVIDENCE_DIR:-$ROOT/.opsforge/evidence/db-002}"
HOLDER_APP="opsforge-db002-holder"
WAITER_APP="opsforge-db002-waiter"
TARGET_ID="${DB002_TARGET_ID:-42}"

mkdir -p "$EVIDENCE_DIR"
HOLDER_EXEC_PID=""
WAITER_EXEC_PID=""

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

psql_app() {
  local app_name="${1:?application name required}"
  shift
  compose exec -T -e PGAPPNAME="$app_name" db psql \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 \
    "$@"
}

terminate_named_sessions() {
  psql_cmd -X -Atc "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE application_name IN ('$HOLDER_APP', '$WAITER_APP')
      AND pid <> pg_backend_pid();
  " >/dev/null 2>&1 || true
}

cleanup() {
  terminate_named_sessions
  if [[ -n "$WAITER_EXEC_PID" ]]; then
    wait "$WAITER_EXEC_PID" 2>/dev/null || true
  fi
  if [[ -n "$HOLDER_EXEC_PID" ]]; then
    wait "$HOLDER_EXEC_PID" 2>/dev/null || true
  fi
}

wait_for_holder() {
  for _ in {1..30}; do
    local count
    count=$(psql_cmd -X -Atc "
      SELECT count(*)
      FROM pg_stat_activity
      WHERE application_name = '$HOLDER_APP'
        AND state = 'active';
    ")
    if [[ "$count" = "1" ]]; then
      return 0
    fi
    sleep 0.5
  done
  echo "DB-002 holder session did not become active" >&2
  return 1
}

wait_for_blocked_waiter() {
  for _ in {1..40}; do
    local count
    count=$(psql_cmd -X -Atc "
      SELECT count(*)
      FROM pg_stat_activity
      WHERE application_name = '$WAITER_APP'
        AND wait_event_type = 'Lock'
        AND cardinality(pg_blocking_pids(pid)) > 0;
    ")
    if [[ "$count" = "1" ]]; then
      return 0
    fi
    sleep 0.5
  done
  echo "DB-002 waiter did not enter a blocked Lock wait" >&2
  return 1
}

capture_diagnostics() {
  psql_cmd -X -P pager=off -c "
    SELECT now() AS observed_at,
           w.pid AS waiter_pid,
           w.application_name AS waiter_application,
           w.state AS waiter_state,
           w.wait_event_type,
           w.wait_event,
           h.pid AS blocker_pid,
           h.application_name AS blocker_application,
           h.state AS blocker_state,
           age(clock_timestamp(), h.xact_start) AS blocker_xact_age,
           pg_blocking_pids(w.pid) AS blocking_pids
    FROM pg_stat_activity w
    JOIN pg_stat_activity h
      ON h.pid = ANY(pg_blocking_pids(w.pid))
    WHERE w.application_name = '$WAITER_APP'
      AND h.application_name = '$HOLDER_APP';
  " | tee "$EVIDENCE_DIR/blocker-map.txt"

  psql_cmd -X -P pager=off -c "
    SELECT a.pid,
           a.application_name,
           a.state,
           a.wait_event_type,
           a.wait_event,
           l.locktype,
           l.mode,
           l.granted,
           CASE WHEN l.relation IS NULL THEN NULL ELSE l.relation::regclass::text END AS relation
    FROM pg_stat_activity a
    JOIN pg_locks l ON l.pid = a.pid
    WHERE a.application_name IN ('$HOLDER_APP', '$WAITER_APP')
    ORDER BY a.application_name, l.granted, l.locktype, l.mode;
  " | tee "$EVIDENCE_DIR/lock-inventory.txt"

  if ! grep -q "$WAITER_APP" "$EVIDENCE_DIR/blocker-map.txt"; then
    echo "DB-002 diagnostics did not capture the waiter" >&2
    return 1
  fi
  if ! grep -q "$HOLDER_APP" "$EVIDENCE_DIR/blocker-map.txt"; then
    echo "DB-002 diagnostics did not capture the blocker" >&2
    return 1
  fi
  if ! grep -q "Lock" "$EVIDENCE_DIR/blocker-map.txt"; then
    echo "DB-002 diagnostics did not capture wait_event_type=Lock" >&2
    return 1
  fi
}

baseline() {
  terminate_named_sessions
  psql_cmd -X -Atc "SELECT count(*) FROM customer_activity WHERE id = $TARGET_ID;" \
    | tee "$EVIDENCE_DIR/baseline-target-count.txt"
  psql_cmd -X -c "SET lock_timeout = '2s'; UPDATE customer_activity SET payload = payload WHERE id = $TARGET_ID;" \
    | tee "$EVIDENCE_DIR/baseline-update.txt"
  echo "DB-002 baseline verified: target row is writable without a lock wait."
}

exercise() {
  trap cleanup EXIT
  baseline

  psql_app "$HOLDER_APP" -X -c "
    BEGIN;
    UPDATE customer_activity SET payload = payload WHERE id = $TARGET_ID;
    SELECT pg_sleep(45);
    ROLLBACK;
  " >"$EVIDENCE_DIR/holder-session.log" 2>&1 &
  HOLDER_EXEC_PID=$!

  wait_for_holder

  psql_app "$WAITER_APP" -X -c "
    SET lock_timeout = '30s';
    UPDATE customer_activity SET payload = payload WHERE id = $TARGET_ID;
  " >"$EVIDENCE_DIR/waiter-session.log" 2>&1 &
  WAITER_EXEC_PID=$!

  wait_for_blocked_waiter
  capture_diagnostics

  HOLDER_DB_PID=$(psql_cmd -X -Atc "
    SELECT pid
    FROM pg_stat_activity
    WHERE application_name = '$HOLDER_APP';
  ")
  WAITER_DB_PID=$(psql_cmd -X -Atc "
    SELECT pid
    FROM pg_stat_activity
    WHERE application_name = '$WAITER_APP';
  ")
  printf 'holder_pid=%s\nwaiter_pid=%s\n' "$HOLDER_DB_PID" "$WAITER_DB_PID" \
    | tee "$EVIDENCE_DIR/session-pids.txt"

  if [[ -z "$HOLDER_DB_PID" || -z "$WAITER_DB_PID" ]]; then
    echo "DB-002 failed to resolve holder/waiter backend PIDs" >&2
    return 1
  fi

  psql_cmd -X -Atc "SELECT pg_terminate_backend($HOLDER_DB_PID);" \
    | tee "$EVIDENCE_DIR/recovery-action.txt"

  wait "$WAITER_EXEC_PID"
  WAITER_EXEC_PID=""
  wait "$HOLDER_EXEC_PID" 2>/dev/null || true
  HOLDER_EXEC_PID=""

  if ! grep -q "UPDATE 1" "$EVIDENCE_DIR/waiter-session.log"; then
    echo "DB-002 waiting update did not complete after blocker termination" >&2
    cat "$EVIDENCE_DIR/waiter-session.log" >&2
    return 1
  fi

  verify
  echo "DB-002 exercise verified: lock blocker identified, terminated, and waiting update recovered."
}

verify() {
  local blocked_count
  blocked_count=$(psql_cmd -X -Atc "
    SELECT count(*)
    FROM pg_stat_activity
    WHERE application_name IN ('$HOLDER_APP', '$WAITER_APP')
      AND wait_event_type = 'Lock';
  ")
  printf '%s\n' "$blocked_count" | tee "$EVIDENCE_DIR/post-recovery-blocked-count.txt"
  if [[ "$blocked_count" != "0" ]]; then
    echo "DB-002 recovery left a lock-waiting session behind" >&2
    return 1
  fi

  psql_cmd -X -c "SET lock_timeout = '2s'; UPDATE customer_activity SET payload = payload WHERE id = $TARGET_ID;" \
    | tee "$EVIDENCE_DIR/post-recovery-update.txt"
  if ! grep -q "UPDATE 1" "$EVIDENCE_DIR/post-recovery-update.txt"; then
    echo "DB-002 post-recovery update did not succeed" >&2
    return 1
  fi
  echo "DB-002 recovery verified: no lock waiter remains and target row is writable."
}

case "$ACTION" in
  baseline)
    baseline
    ;;
  exercise)
    exercise
    ;;
  diagnose)
    capture_diagnostics
    ;;
  verify)
    verify
    ;;
  *)
    echo "Unsupported action: $ACTION" >&2
    exit 2
    ;;
esac
