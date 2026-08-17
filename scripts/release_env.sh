#!/usr/bin/env bash
set -euo pipefail

OPSFORGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_opsforge_secrets() {
  if [[ -f "$OPSFORGE_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$OPSFORGE_ROOT/.env"
    set +a
  fi
}

configure_opsforge_environment() {
  local environment="${1:?environment is required}"

  case "$environment" in
    staging)
      export OPSFORGE_PROJECT_NAME="opsforge-staging"
      export OPSFORGE_CONTAINER_PREFIX="nightwatch-staging"
      export OPSFORGE_NETWORK_NAME="nightwatch-staging-net"
      export APP_ENV="staging"
      export API_HOST_PORT="18000"
      export NGINX_HTTP_HOST_PORT="18080"
      export NGINX_HTTPS_HOST_PORT="18443"
      export RABBITMQ_MANAGEMENT_HOST_PORT="25672"
      export PROMETHEUS_HOST_PORT="19090"
      export LOKI_HOST_PORT="13100"
      export TEMPO_HTTP_HOST_PORT="13200"
      export TEMPO_GRPC_HOST_PORT="14317"
      export TEMPO_OTLP_HTTP_HOST_PORT="14318"
      export GRAFANA_HOST_PORT="13000"
      ;;
    production)
      export OPSFORGE_PROJECT_NAME="opsforge-production"
      export OPSFORGE_CONTAINER_PREFIX="nightwatch-production"
      export OPSFORGE_NETWORK_NAME="nightwatch-production-net"
      export APP_ENV="production"
      export API_HOST_PORT="8000"
      export NGINX_HTTP_HOST_PORT="8080"
      export NGINX_HTTPS_HOST_PORT="8443"
      export RABBITMQ_MANAGEMENT_HOST_PORT="15672"
      export PROMETHEUS_HOST_PORT="9090"
      export LOKI_HOST_PORT="3100"
      export TEMPO_HTTP_HOST_PORT="3200"
      export TEMPO_GRPC_HOST_PORT="4317"
      export TEMPO_OTLP_HTTP_HOST_PORT="4318"
      export GRAFANA_HOST_PORT="3000"
      ;;
    *)
      echo "Unsupported OPSFORGE environment: $environment" >&2
      return 2
      ;;
  esac

  export OPSFORGE_ENVIRONMENT="$environment"
  export OPSFORGE_STATE_DIR="$OPSFORGE_ROOT/.opsforge/state"
}

opsforge_compose() {
  docker compose \
    -p "$OPSFORGE_PROJECT_NAME" \
    -f "$OPSFORGE_ROOT/docker-compose.yml" \
    "$@"
}
