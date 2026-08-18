#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: build_release.sh <version> [fault-mode]}"
FAULT_MODE="${2:-none}"

if [[ ! "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid release version: $VERSION" >&2
  exit 2
fi

case "$FAULT_MODE" in
  none|ticket-create-500|ticket-read-api-500|ticket-read-dependency-timeout) ;;
  *)
    echo "Unsupported release fault mode: $FAULT_MODE" >&2
    exit 2
    ;;
esac

GIT_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')"
COMMON_LABELS=(
  --label "org.opencontainers.image.revision=$GIT_SHA"
  --label "org.opencontainers.image.version=$VERSION"
  --label "io.opsforge.release=$VERSION"
)

echo "Building OPSFORGE release $VERSION (fault mode: $FAULT_MODE)"

docker build \
  "${COMMON_LABELS[@]}" \
  --build-arg "OPSFORGE_RELEASE_FAULT_MODE=$FAULT_MODE" \
  -t "nightwatch-api:$VERSION" \
  "$ROOT/api"
docker build "${COMMON_LABELS[@]}" -t "nightwatch-worker:$VERSION" "$ROOT/worker"
docker build \
  "${COMMON_LABELS[@]}" \
  --build-arg "OPSFORGE_RELEASE_FAULT_MODE=$FAULT_MODE" \
  -t "nightwatch-nginx:$VERSION" \
  "$ROOT/nginx"
docker build "${COMMON_LABELS[@]}" -t "nightwatch-synthetic:$VERSION" "$ROOT/synthetic"

mkdir -p "$ROOT/.opsforge/releases"
cat > "$ROOT/.opsforge/releases/$VERSION.json" <<EOF
{
  "version": "$VERSION",
  "git_sha": "$GIT_SHA",
  "fault_mode": "$FAULT_MODE",
  "images": {
    "api": "nightwatch-api:$VERSION",
    "worker": "nightwatch-worker:$VERSION",
    "nginx": "nightwatch-nginx:$VERSION",
    "synthetic": "nightwatch-synthetic:$VERSION"
  }
}
EOF

cat "$ROOT/.opsforge/releases/$VERSION.json"
