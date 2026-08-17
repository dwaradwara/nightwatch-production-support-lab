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

CURRENT_VERSION=""
if [[ -f "$OPSFORGE_STATE_DIR/$ENVIRONMENT.current" ]]; then
  CURRENT_VERSION="$(cat "$OPSFORGE_STATE_DIR/$ENVIRONMENT.current")"
fi

bash "$ROOT/scripts/deploy_release.sh" "$ENVIRONMENT" "$VERSION"

if bash "$ROOT/scripts/verify_release.sh" "$ENVIRONMENT" "$VERSION"; then
  if [[ -n "$CURRENT_VERSION" && "$CURRENT_VERSION" != "$VERSION" ]]; then
    printf '%s\n' "$CURRENT_VERSION" > "$OPSFORGE_STATE_DIR/$ENVIRONMENT.previous"
  fi
  printf '%s\n' "$VERSION" > "$OPSFORGE_STATE_DIR/$ENVIRONMENT.current"
  rm -f "$OPSFORGE_STATE_DIR/$ENVIRONMENT.candidate"
  echo "Promotion accepted: environment=$ENVIRONMENT version=$VERSION"
  exit 0
fi

echo "Promotion rejected: environment=$ENVIRONMENT version=$VERSION" >&2

if [[ "$ENVIRONMENT" = "production" && -n "$CURRENT_VERSION" ]]; then
  echo "A last-good production version exists: $CURRENT_VERSION" >&2
  bash "$ROOT/scripts/rollback_release.sh" production "$CURRENT_VERSION"
  echo "Rejected production release was rolled back automatically." >&2
fi

exit 1
