#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_env.sh"

ENVIRONMENT="${1:?usage: rollback_release.sh <staging|production> <last-good-version>}"
LAST_GOOD_VERSION="${2:?usage: rollback_release.sh <staging|production> <last-good-version>}"

load_opsforge_secrets
configure_opsforge_environment "$ENVIRONMENT"
mkdir -p "$OPSFORGE_STATE_DIR"

FAILED_CANDIDATE=""
if [[ -f "$OPSFORGE_STATE_DIR/$ENVIRONMENT.candidate" ]]; then
  FAILED_CANDIDATE="$(cat "$OPSFORGE_STATE_DIR/$ENVIRONMENT.candidate")"
fi

echo "Rolling back $ENVIRONMENT from ${FAILED_CANDIDATE:-unknown-candidate} to $LAST_GOOD_VERSION"

bash "$ROOT/scripts/deploy_release.sh" "$ENVIRONMENT" "$LAST_GOOD_VERSION"
bash "$ROOT/scripts/verify_release.sh" "$ENVIRONMENT" "$LAST_GOOD_VERSION"

printf '%s\n' "$LAST_GOOD_VERSION" > "$OPSFORGE_STATE_DIR/$ENVIRONMENT.current"
rm -f "$OPSFORGE_STATE_DIR/$ENVIRONMENT.candidate"
printf '%s\t%s\t%s\t%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$ENVIRONMENT" \
  "${FAILED_CANDIDATE:-unknown}" \
  "$LAST_GOOD_VERSION" \
  >> "$OPSFORGE_STATE_DIR/rollback-history.tsv"

echo "Rollback verified: environment=$ENVIRONMENT restored=$LAST_GOOD_VERSION"
