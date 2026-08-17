#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_env.sh"

ENVIRONMENT="${1:?usage: deploy_release.sh <staging|production> <version>}"
VERSION="${2:?usage: deploy_release.sh <staging|production> <version>}"

load_opsforge_secrets
configure_opsforge_environment "$ENVIRONMENT"
export RELEASE_VERSION="$VERSION"

for image in \
  "nightwatch-api:$VERSION" \
  "nightwatch-worker:$VERSION" \
  "nightwatch-nginx:$VERSION" \
  "nightwatch-synthetic:$VERSION"; do
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "Release image is missing locally: $image" >&2
    exit 3
  fi
done

mkdir -p "$OPSFORGE_STATE_DIR"
printf '%s\n' "$VERSION" > "$OPSFORGE_STATE_DIR/$ENVIRONMENT.candidate"

echo "Deploying OPSFORGE $VERSION to $ENVIRONMENT"
echo "Compose project: $OPSFORGE_PROJECT_NAME"
echo "Public URL: http://127.0.0.1:$NGINX_HTTP_HOST_PORT"

opsforge_compose up -d --no-build
opsforge_compose ps
