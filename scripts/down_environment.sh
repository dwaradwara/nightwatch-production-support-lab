#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/release_env.sh"

ENVIRONMENT="${1:?usage: down_environment.sh <staging|production> [--volumes]}"
MODE="${2:-}"

load_opsforge_secrets
configure_opsforge_environment "$ENVIRONMENT"

if [[ "$MODE" = "--volumes" ]]; then
  opsforge_compose down -v --remove-orphans
else
  opsforge_compose down --remove-orphans
fi
