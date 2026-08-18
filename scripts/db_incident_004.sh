#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:?usage: db_incident_004.sh <baseline|exercise|diagnose|verify>}"
PROJECT_NAME="${OPSFORGE_PROJECT_NAME:-opsforge-db004}"
POSTGRES_USER="${POSTGRES_USER:-nightwatch}"
POSTGRES_DB="${POSTGRES_DB:-nightwatch}"
EVIDENCE_DIR="${DB004_EVIDENCE_DIR:-$ROOT/.opsforge/evidence/db-004}"
APP_ROLE="opsforge_app"
APP_PASSWORD="${DB004_APP_PASSWORD:-opsforge-db004-app-password}"
POOL_PREFIX="opsforge-db004-pool"
PROBE_APP="opsforge-db004-probe"
TARGET_MAX_CONNECTIONS="${DB004_MAX_CONNECTIONS:-12}"
POOL_HOLD_SECONDS="${DB004_POOL_HOLD_SECONDS:-20}"
POOL_PIDS=()
CONFIG_CHANGED=0

mkdir -p "$EVIDENCE_DIR"

compose() {
  docker compose -p "$PROJECT_NAME" -f "$ROOT/docker-compose.yml" "$@"
}

admin_psql() {
  compose exec -T db psql \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 \
    "$@"
}

app_psql() {
  compose exec -T \
    -e PGAPPNAME="$PROBE_APP" \
    -e PGPASSWORD="$APP_PASSWORD" \
    db psql \
      -h 127.0.0.1 \
      -U "$APP_ROLE" \
      -d "$POSTGRES_DB" \
      -v ON_ERROR_STOP=1 \
      "$@"
}

wait_for_db() {
  for _ in {1..40}; do
    local ready
    ready=$(admin_psql -X -Atc "SELECT count(*) FROM customer_activity WHERE id = 84;" 2>/dev/null || true)
    if [[ "$ready" = "1" ]]; then
      sleep 2
      local stable
      stable=$(admin_psql -X -Atc "SELECT count(*) FROM customer_activity WHERE id = 84;" 2>/dev/null || true)
      if [[ "$stable" = "1" ]]; then
        return 0
      fi
    fi
    sleep 1
  done

  compose logs db
  echo "DB-004 database did not reach stable seeded readiness" >&2
  return 1
}

ensure_app_role() {
  admin_psql -X -c "
    DO \$\$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$APP_ROLE') THEN
        CREATE ROLE $APP_ROLE LOGIN PASSWORD '$APP_PASSWORD';
      ELSE
        ALTER ROLE $APP_ROLE LOGIN PASSWORD '$APP_PASSWORD';
      END IF;
    END
    \$\$;
    GRANT CONNECT ON DATABASE $POSTGRES_DB TO $APP_ROLE;
    GRANT USAGE ON SCHEMA public TO $APP_ROLE;
    GRANT SELECT ON customer_activity TO $APP_ROLE;
  " >/dev/null
}

terminate_pool_sessions() {
  admin_psql -X -Atc "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE application_name LIKE '${POOL_PREFIX}-%'
      AND pid <> pg_backend_pid();
  " >/dev/null 2>&1 || true
}

wait_for_pool_children() {
  local pid
  for pid in "${POOL_PIDS[@]:-}"; do
    if [[ -n "$pid" ]]; then
      wait "$pid" 2>/dev/null || true
    fi
  done
  POOL_PIDS=()
}

restore_configuration() {
  if [[ "$CONFIG_CHANGED" = "1" ]]; then
    admin_psql -X -c "ALTER SYSTEM RESET max_connections;" >/dev/null 2>&1 || true
    compose restart db >/dev/null 2>&1 || true
    wait_for_db >/dev/null 2>&1 || true
    CONFIG_CHANGED=0
  fi
}

cleanup() {
  terminate_pool_sessions
  wait_for_pool_children
  restore_configuration
}

baseline() {
  ensure_app_role
  terminate_pool_sessions

  admin_psql -X -Atc "SHOW max_connections;" \
    | tee "$EVIDENCE_DIR/baseline-max-connections.txt"

  app_psql -X -Atc "SELECT 1;" \
    | tee "$EVIDENCE_DIR/baseline-app-connection.txt"

  if ! grep -qx "1" "$EVIDENCE_DIR/baseline-app-connection.txt"; then
    echo "DB-004 baseline application connection failed" >&2
    return 1
  fi

  echo "DB-004 baseline verified: ordinary application role can connect."
}

configure_small_connection_budget() {
  admin_psql -X -c "ALTER SYSTEM SET max_connections = '$TARGET_MAX_CONNECTIONS';" >/dev/null
  CONFIG_CHANGED=1
  compose restart db >/dev/null
  wait_for_db

  local current
  current=$(admin_psql -X -Atc "SHOW max_connections;")
  printf '%s\n' "$current" | tee "$EVIDENCE_DIR/incident-max-connections.txt"
  if [[ "$current" != "$TARGET_MAX_CONNECTIONS" ]]; then
    echo "DB-004 failed to apply isolated max_connections target" >&2
    return 1
  fi
}

ordinary_slot_budget() {
  admin_psql -X -Atc "
    SELECT current_setting('max_connections')::int
         - current_setting('superuser_reserved_connections')::int
         - COALESCE(NULLIF(current_setting('reserved_connections', true), '')::int, 0);
  "
}

start_pool_session() {
  local index="$1"
  local app_name
  app_name=$(printf '%s-%02d' "$POOL_PREFIX" "$index")
  (
    {
      printf 'SELECT 1;\n'
      sleep "$POOL_HOLD_SECONDS"
    } | compose exec -T \
          -e PGAPPNAME="$app_name" \
          -e PGPASSWORD="$APP_PASSWORD" \
          db psql \
            -h 127.0.0.1 \
            -U "$APP_ROLE" \
            -d "$POSTGRES_DB" \
            -v ON_ERROR_STOP=1
  ) >"$EVIDENCE_DIR/${app_name}.log" 2>&1 &
  POOL_PIDS+=("$!")
}

fill_ordinary_slots() {
  local budget
  budget=$(ordinary_slot_budget)
  printf '%s\n' "$budget" | tee "$EVIDENCE_DIR/ordinary-slot-budget.txt"

  if (( budget < 2 )); then
    echo "DB-004 ordinary connection budget is too small for safe exercise" >&2
    return 1
  fi

  local i
  for ((i=1; i<=budget; i++)); do
    start_pool_session "$i"
  done

  for _ in {1..40}; do
    local count
    count=$(admin_psql -X -Atc "
      SELECT count(*)
      FROM pg_stat_activity
      WHERE application_name LIKE '${POOL_PREFIX}-%';
    ")
    if [[ "$count" = "$budget" ]]; then
      printf '%s\n' "$count" | tee "$EVIDENCE_DIR/pool-session-count.txt"
      return 0
    fi
    sleep 0.25
  done

  echo "DB-004 pool did not consume the expected ordinary connection slots" >&2
  return 1
}

capture_diagnostics() {
  admin_psql -X -P pager=off -c "
    SELECT name, setting
    FROM pg_settings
    WHERE name IN ('max_connections', 'superuser_reserved_connections', 'reserved_connections')
    ORDER BY name;
  " | tee "$EVIDENCE_DIR/connection-settings.txt"

  admin_psql -X -P pager=off -c "
    SELECT application_name, usename, state, count(*) AS sessions
    FROM pg_stat_activity
    GROUP BY application_name, usename, state
    ORDER BY sessions DESC, application_name;
  " | tee "$EVIDENCE_DIR/session-inventory.txt"

  admin_psql -X -Atc "
    SELECT count(*)
    FROM pg_stat_activity
    WHERE application_name LIKE '${POOL_PREFIX}-%';
  " | tee "$EVIDENCE_DIR/diagnosed-pool-session-count.txt"

  admin_psql -X -Atc "SELECT 1;" \
    | tee "$EVIDENCE_DIR/reserved-admin-path.txt"
}

prove_application_exhaustion() {
  if app_psql -X -Atc "SELECT 1;" >"$EVIDENCE_DIR/exhausted-app-connection.txt" 2>&1; then
    echo "DB-004 expected ordinary application connection failure, but connection succeeded" >&2
    return 1
  fi

  cat "$EVIDENCE_DIR/exhausted-app-connection.txt"
  if ! grep -Eqi "remaining connection slots|too many clients" "$EVIDENCE_DIR/exhausted-app-connection.txt"; then
    echo "DB-004 application connection failed for an unexpected reason" >&2
    return 1
  fi

  echo "DB-004 application connection failure proven while administrative access remains available."
}

diagnose() {
  capture_diagnostics

  local budget pool_count admin_ok
  budget=$(ordinary_slot_budget)
  pool_count=$(admin_psql -X -Atc "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '${POOL_PREFIX}-%';")
  admin_ok=$(cat "$EVIDENCE_DIR/reserved-admin-path.txt")

  if [[ "$pool_count" != "$budget" ]]; then
    echo "DB-004 diagnosis expected pool count $budget, found $pool_count" >&2
    return 1
  fi
  if [[ "$admin_ok" != "1" ]]; then
    echo "DB-004 reserved administrative recovery path was not available" >&2
    return 1
  fi

  echo "DB-004 diagnosis verified: named pool consumed all ordinary application slots while reserved admin access survived."
}

recover_one_slot() {
  local target_pid target_app
  read -r target_pid target_app < <(admin_psql -X -At -F ' ' -c "
    SELECT pid, application_name
    FROM pg_stat_activity
    WHERE application_name LIKE '${POOL_PREFIX}-%'
    ORDER BY backend_start, pid
    LIMIT 1;
  ")

  if [[ -z "${target_pid:-}" || -z "${target_app:-}" ]]; then
    echo "DB-004 recovery refused: no evidence-matched pool backend found" >&2
    return 1
  fi

  printf 'target_pid=%s\napplication_name=%s\n' "$target_pid" "$target_app" \
    | tee "$EVIDENCE_DIR/recovery-target.txt"

  admin_psql -X -Atc "SELECT pg_terminate_backend($target_pid);" \
    | tee "$EVIDENCE_DIR/recovery-action.txt"

  if ! grep -qx "t" "$EVIDENCE_DIR/recovery-action.txt"; then
    echo "DB-004 targeted backend termination failed" >&2
    return 1
  fi

  for _ in {1..20}; do
    if app_psql -X -Atc "SELECT 1;" >"$EVIDENCE_DIR/post-recovery-app-connection.txt" 2>&1; then
      cat "$EVIDENCE_DIR/post-recovery-app-connection.txt"
      return 0
    fi
    sleep 0.25
  done

  cat "$EVIDENCE_DIR/post-recovery-app-connection.txt" >&2 || true
  echo "DB-004 application connection did not recover after releasing one ordinary slot" >&2
  return 1
}

verify() {
  if ! grep -qx "1" "$EVIDENCE_DIR/post-recovery-app-connection.txt"; then
    echo "DB-004 recovery proof does not contain a successful application connection" >&2
    return 1
  fi

  admin_psql -X -Atc "SELECT 1;" \
    | tee "$EVIDENCE_DIR/post-recovery-admin-health.txt"

  local budget remaining
  budget=$(ordinary_slot_budget)
  remaining=$(admin_psql -X -Atc "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '${POOL_PREFIX}-%';")
  printf '%s\n' "$remaining" | tee "$EVIDENCE_DIR/post-recovery-pool-session-count.txt"

  if (( remaining >= budget )); then
    echo "DB-004 expected at least one ordinary slot to remain free after mitigation" >&2
    return 1
  fi

  echo "DB-004 recovery verified: one targeted pool termination restored ordinary application connectivity without restarting PostgreSQL."
}

exercise() {
  trap cleanup EXIT
  baseline
  configure_small_connection_budget
  ensure_app_role
  fill_ordinary_slots
  prove_application_exhaustion
  diagnose
  recover_one_slot
  verify

  terminate_pool_sessions
  wait_for_pool_children
  admin_psql -X -Atc "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '${POOL_PREFIX}-%';" \
    | tee "$EVIDENCE_DIR/post-cleanup-pool-session-count.txt"
  restore_configuration
  admin_psql -X -Atc "SHOW max_connections;" \
    | tee "$EVIDENCE_DIR/restored-max-connections.txt"

  echo "DB-004 exercise verified: ordinary slots exhausted, evidence captured, one targeted slot released, application connectivity recovered, and isolated configuration restored."
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
