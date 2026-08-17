#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_env.sh"

ENVIRONMENT="${1:?usage: promote_release.sh <staging|production> <version>}"
VERSION="${2:?usage: promote_release.sh <staging|production> <version>}"

load_opsforge_secrets
configure_opsforge_environment "$ENVIRONMENT"
mkdir -p "$OPSFORGE_STATE_DIR"

DIAGNOSTIC_DIR="$ROOT/.opsforge/diagnostics/$ENVIRONMENT-$VERSION"
mkdir -p "$DIAGNOSTIC_DIR"
PROMOTION_LOG="$DIAGNOSTIC_DIR/promotion.log"

CURRENT_VERSION=""
if [[ -f "$OPSFORGE_STATE_DIR/$ENVIRONMENT.current" ]]; then
  CURRENT_VERSION="$(cat "$OPSFORGE_STATE_DIR/$ENVIRONMENT.current")"
fi

printf 'environment=%s\nversion=%s\nstage=deploy\n' "$ENVIRONMENT" "$VERSION" \
  > "$DIAGNOSTIC_DIR/promotion-state.txt"

set +e
bash "$ROOT/scripts/deploy_release.sh" "$ENVIRONMENT" "$VERSION" 2>&1 | tee -a "$PROMOTION_LOG"
DEPLOY_STATUS=${PIPESTATUS[0]}
set -e

if [[ "$DEPLOY_STATUS" -ne 0 ]]; then
  printf 'environment=%s\nversion=%s\nstage=deploy\nstatus=failed\nexit_code=%s\n' \
    "$ENVIRONMENT" "$VERSION" "$DEPLOY_STATUS" \
    > "$DIAGNOSTIC_DIR/promotion-state.txt"
  echo "::error title=OPSFORGE deployment failed::environment=$ENVIRONMENT version=$VERSION exit_code=$DEPLOY_STATUS"
  echo "Deployment failed before release verification: environment=$ENVIRONMENT version=$VERSION" >&2
  exit "$DEPLOY_STATUS"
fi

printf 'environment=%s\nversion=%s\nstage=verification\n' "$ENVIRONMENT" "$VERSION" \
  > "$DIAGNOSTIC_DIR/promotion-state.txt"

set +e
bash "$ROOT/scripts/verify_release.sh" "$ENVIRONMENT" "$VERSION" 2>&1 | tee -a "$PROMOTION_LOG"
VERIFY_STATUS=${PIPESTATUS[0]}
set -e

if [[ "$VERIFY_STATUS" -eq 0 ]]; then
  if [[ -n "$CURRENT_VERSION" && "$CURRENT_VERSION" != "$VERSION" ]]; then
    printf '%s\n' "$CURRENT_VERSION" > "$OPSFORGE_STATE_DIR/$ENVIRONMENT.previous"
  fi
  printf '%s\n' "$VERSION" > "$OPSFORGE_STATE_DIR/$ENVIRONMENT.current"
  rm -f "$OPSFORGE_STATE_DIR/$ENVIRONMENT.candidate"
  printf 'environment=%s\nversion=%s\nstage=accepted\nstatus=passed\n' "$ENVIRONMENT" "$VERSION" \
    > "$DIAGNOSTIC_DIR/promotion-state.txt"
  echo "Promotion accepted: environment=$ENVIRONMENT version=$VERSION"
  exit 0
fi

printf 'environment=%s\nversion=%s\nstage=verification\nstatus=failed\nexit_code=%s\n' \
  "$ENVIRONMENT" "$VERSION" "$VERIFY_STATUS" \
  > "$DIAGNOSTIC_DIR/promotion-state.txt"

FAILED_CHECK="unknown verification check"
if [[ -f "$DIAGNOSTIC_DIR/failure.txt" ]]; then
  FAILED_CHECK=$(awk -F= '$1=="check" {print substr($0, index($0, "=") + 1)}' "$DIAGNOSTIC_DIR/failure.txt")
  [[ -n "$FAILED_CHECK" ]] || FAILED_CHECK="unknown verification check"
fi
echo "::error title=OPSFORGE release verification failed::environment=$ENVIRONMENT version=$VERSION check=$FAILED_CHECK"
echo "Promotion rejected: environment=$ENVIRONMENT version=$VERSION" >&2

if [[ "$ENVIRONMENT" = "production" && -n "$CURRENT_VERSION" ]]; then
  echo "A last-good production version exists: $CURRENT_VERSION" >&2
  bash "$ROOT/scripts/rollback_release.sh" production "$CURRENT_VERSION"
  echo "Rejected production release was rolled back automatically." >&2
fi

exit "$VERIFY_STATUS"
