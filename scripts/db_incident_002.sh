#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${OPSFORGE_PROJECT_NAME:-opsforge-db002}"
POSTGRES_USER="${POSTGRES_USER:-nightwatch}"
POSTGRES_DB="${POSTGRES_DB:-nightwatch}"
EVIDENCE_DIR="${DB002_EVIDENCE_DIR:-$ROOT_DIR/.opsforge/evidence/db-002}"
CUSTOMER_ID="customer-0042"
BLOCKER_APP="opsforge-db002-blocker"
WAITER_APP="opsforge-db002-waiter"

compose() {
  docker compose -p "$PROJECT_NAME" -f "$ROOT_DIR/docker-compose.yml" "$@"
}

db_psql() {
  compose exec -T db psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"
}

scalar() {
  db_psql -Atc "$1" | tr -d '\r'
}

db_container_id() {
  compose ps -q db
}

wait_for_sql() {
  local sql="$1"
  local expected="$2"
  local attempts="${3:-30}"
  for ((i=1; i<=attempts; i++)); do
    if [[ "$(scalar "$sql")" == "$expected" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

mkdir -p "$EVIDENCE_DIR"

case "${1:-}" in
  baseline)
    active_sessions="$(scalar "SELECT count(*) FROM pg_stat_activity WHERE application_name IN ('$BLOCKER_APP', '$WAITER_APP');")"
    if [[ "$active_sessions" != "0" ]]; then
      echo "DB-002 baseline refused: previous exercise sessions are still active." >&2
      exit 1
    fi

    db_psql -c "UPDATE customer_account_state SET state = 'Normal', updated_at = NOW() WHERE customer_id = '$CUSTOMER_ID';" >/dev/null
    db_psql -c "SELECT customer_id, state, updated_at FROM customer_account_state WHERE customer_id = '$CUSTOMER_ID';" \
      | tee "$EVIDENCE_DIR/baseline-row.txt"
    db_psql -c "SELECT now() AS observed_at, current_database() AS database, count(*) AS active_connections FROM pg_stat_activity WHERE datname = current_database();" \
      | tee "$EVIDENCE_DIR/baseline-db-state.txt"

    if [[ "$(scalar "SELECT state FROM customer_account_state WHERE customer_id = '$CUSTOMER_ID';")" != "Normal" ]]; then
      echo "DB-002 baseline failed: fixture row is not Normal." >&2
      exit 1
    fi
    echo "DB-002 baseline verified: target row is writable and no exercise sessions are active."
    ;;

  inject)
    container_id="$(db_container_id)"
    if [[ -z "$container_id" ]]; then
      echo "DB-002 injection failed: PostgreSQL container is not running." >&2
      exit 1
    fi

    # Start a transaction that acquires a row lock and remains open. The
    # application_name makes the training session identifiable and lets the
    # recovery action target only the proven blocker.
    docker exec -d "$container_id" sh -c "exec psql -X -v ON_ERROR_STOP=1 -U '$POSTGRES_USER' -d '$POSTGRES_DB' 'application_name=$BLOCKER_APP' -c \"BEGIN; UPDATE customer_account_state SET state = 'BlockedByTransaction', updated_at = NOW() WHERE customer_id = '$CUSTOMER_ID'; SELECT pg_sleep(300); COMMIT;\" >/tmp/db002-blocker.log 2>&1"

    if ! wait_for_sql "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$BLOCKER_APP' AND xact_start IS NOT NULL;" "1" 20; then
      echo "DB-002 injection failed: blocker transaction did not become active." >&2
      compose logs db >&2 || true
      exit 1
    fi

    # A second session attempts to update the same row. It should block on the
    # first transaction while PostgreSQL remains otherwise reachable.
    docker exec -d "$container_id" sh -c "exec psql -X -v ON_ERROR_STOP=1 -U '$POSTGRES_USER' -d '$POSTGRES_DB' 'application_name=$WAITER_APP' -c \"SET lock_timeout = '180s'; UPDATE customer_account_state SET state = 'Investigating', updated_at = NOW() WHERE customer_id = '$CUSTOMER_ID';\" >/tmp/db002-waiter.log 2>&1"

    if ! wait_for_sql "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$WAITER_APP' AND wait_event_type = 'Lock';" "1" 20; then
      echo "DB-002 injection failed: waiter did not enter a lock wait." >&2
      db_psql -c "SELECT pid, application_name, state, wait_event_type, wait_event, query FROM pg_stat_activity WHERE application_name IN ('$BLOCKER_APP', '$WAITER_APP');" >&2 || true
      exit 1
    fi

    echo "DB-002 injected: one transaction holds the row lock and a second transaction is waiting."
    ;;

  diagnose)
    # Reachability check proves this is not a database outage.
    db_psql -c "SELECT 1 AS database_reachable;" | tee "$EVIDENCE_DIR/database-reachability.txt"

    db_psql -c "
      SELECT pid, application_name, state, wait_event_type, wait_event,
             xact_start, query_start, now() - xact_start AS transaction_age,
             left(query, 180) AS query
      FROM pg_stat_activity
      WHERE application_name IN ('$BLOCKER_APP', '$WAITER_APP')
      ORDER BY application_name;
    " | tee "$EVIDENCE_DIR/activity.txt"

    db_psql -c "
      SELECT blocked.pid AS blocked_pid,
             blocked.application_name AS blocked_application,
             blocked.wait_event_type,
             blocked.wait_event,
             blocker.pid AS blocker_pid,
             blocker.application_name AS blocker_application,
             now() - blocker.xact_start AS blocker_transaction_age
      FROM pg_stat_activity AS blocked
      CROSS JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS blocking_pid
      JOIN pg_stat_activity AS blocker ON blocker.pid = blocking_pid
      WHERE blocked.application_name = '$WAITER_APP';
    " | tee "$EVIDENCE_DIR/blocking-chain.txt"

    db_psql -c "
      SELECT a.pid, a.application_name, l.locktype, l.mode, l.granted,
             l.relation::regclass AS relation, l.transactionid, l.tuple
      FROM pg_locks AS l
      JOIN pg_stat_activity AS a ON a.pid = l.pid
      WHERE a.application_name IN ('$BLOCKER_APP', '$WAITER_APP')
      ORDER BY a.application_name, l.granted, l.locktype;
    " | tee "$EVIDENCE_DIR/locks.txt"

    waiter_waiting="$(scalar "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$WAITER_APP' AND wait_event_type = 'Lock';")"
    blocker_pair="$(scalar "SELECT count(*) FROM pg_stat_activity b WHERE b.application_name = '$WAITER_APP' AND EXISTS (SELECT 1 FROM unnest(pg_blocking_pids(b.pid)) p(pid) JOIN pg_stat_activity x ON x.pid = p.pid WHERE x.application_name = '$BLOCKER_APP');")"

    if [[ "$waiter_waiting" != "1" || "$blocker_pair" != "1" ]]; then
      echo "DB-002 diagnosis failed: expected blocker/waiter relationship was not proven." >&2
      exit 1
    fi

    echo "DB-002 diagnosis verified: database is reachable and the waiter is blocked by the identified transaction."
    ;;

  recover)
    blocker_pid="$(scalar "SELECT pid FROM pg_stat_activity WHERE application_name = '$BLOCKER_APP' ORDER BY backend_start LIMIT 1;")"
    if [[ -z "$blocker_pid" ]]; then
      echo "DB-002 recovery refused: no proven simulated blocker session exists." >&2
      exit 1
    fi

    # This models an approved targeted recovery. It deliberately does not kill
    # arbitrary sessions or restart PostgreSQL.
    db_psql -c "SELECT pid, application_name, state, xact_start, left(query, 180) AS query FROM pg_stat_activity WHERE pid = $blocker_pid;" \
      | tee "$EVIDENCE_DIR/recovery-target.txt"
    db_psql -c "SELECT pg_terminate_backend($blocker_pid) AS terminated;" \
      | tee "$EVIDENCE_DIR/recovery-action.txt"

    if ! wait_for_sql "SELECT count(*) FROM pg_stat_activity WHERE application_name IN ('$BLOCKER_APP', '$WAITER_APP');" "0" 20; then
      echo "DB-002 recovery failed: simulated blocker/waiter sessions did not clear." >&2
      db_psql -c "SELECT pid, application_name, state, wait_event_type, wait_event FROM pg_stat_activity WHERE application_name IN ('$BLOCKER_APP', '$WAITER_APP');" >&2 || true
      exit 1
    fi

    echo "DB-002 recovery applied: targeted blocker backend terminated and waiting transaction released."
    ;;

  verify)
    db_psql -c "SELECT customer_id, state, updated_at FROM customer_account_state WHERE customer_id = '$CUSTOMER_ID';" \
      | tee "$EVIDENCE_DIR/recovered-row.txt"
    db_psql -c "SELECT count(*) AS blocked_sessions FROM pg_stat_activity WHERE application_name = '$WAITER_APP' AND wait_event_type = 'Lock';" \
      | tee "$EVIDENCE_DIR/recovered-lock-state.txt"

    final_state="$(scalar "SELECT state FROM customer_account_state WHERE customer_id = '$CUSTOMER_ID';")"
    remaining_sessions="$(scalar "SELECT count(*) FROM pg_stat_activity WHERE application_name IN ('$BLOCKER_APP', '$WAITER_APP');")"

    if [[ "$final_state" != "Investigating" ]]; then
      echo "DB-002 verification failed: waiter update did not complete after blocker recovery (state=$final_state)." >&2
      exit 1
    fi
    if [[ "$remaining_sessions" != "0" ]]; then
      echo "DB-002 verification failed: exercise sessions remain active." >&2
      exit 1
    fi

    db_psql -c "UPDATE customer_account_state SET state = 'Normal', updated_at = NOW() WHERE customer_id = '$CUSTOMER_ID';" >/dev/null
    echo "DB-002 recovery verified: blocked update completed, lock wait cleared, and fixture reset to Normal."
    ;;

  *)
    echo "Usage: $0 {baseline|inject|diagnose|recover|verify}" >&2
    exit 2
    ;;
esac
