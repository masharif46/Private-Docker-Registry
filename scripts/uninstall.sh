#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HARBOR_DIR="${HARBOR_DIR:-$ROOT_DIR/harbor}"
CACHE_DIR="${CACHE_DIR:-$ROOT_DIR/dockerhub-cache}"
CACHE_COMPOSE_FILE="$ROOT_DIR/deploy/dockerhub-cache/docker-compose.yml"
CACHE_ENV_FILE="$CACHE_DIR/.env"
CACHE_CONTAINER="private-dockerhub-cache"
CACHE_VOLUME="private-dockerhub-cache-data"
PURGE_DATA=0
CONFIRM=0

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: scripts/uninstall.sh {api|harbor|cache|all} [--purge-data --confirm]

Default behavior stops/removes containers but preserves registry images,
Docker Hub cache layers, credentials, certificates, and Docker volumes.
EOF
}

for argument in "$@"; do
  case "$argument" in
    --purge-data) PURGE_DATA=1 ;;
    --confirm) CONFIRM=1 ;;
    -h|--help) usage; exit 0 ;;
    api|harbor|cache|all) [[ -z "${TARGET:-}" ]] || die 'Choose only one target: api, harbor, cache, or all.'; TARGET="$argument" ;;
    *) die "Unknown argument: $argument" ;;
  esac
done
TARGET="${TARGET:-}"
[[ -n "$TARGET" ]] || { usage; exit 2; }
if (( PURGE_DATA == 1 && CONFIRM != 1 )); then
  die 'Permanent data removal requires both --purge-data and --confirm.'
fi

stop_api() {
  [[ -f "$ROOT_DIR/.env" ]] || return 0
  docker compose --env-file "$ROOT_DIR/.env" -f "$ROOT_DIR/docker-compose.yml" down
  if (( PURGE_DATA == 1 )); then
    docker volume rm private-docker-registry-data >/dev/null 2>&1 || true
    printf 'Purged lightweight registry volume: private-docker-registry-data\n'
  else
    printf 'Preserved lightweight registry volume and images.\n'
  fi
}

stop_harbor() {
  [[ -f "$HARBOR_DIR/docker-compose.yml" ]] || { printf 'Harbor installation not found: %s\n' "$HARBOR_DIR"; return 0; }
  (cd "$HARBOR_DIR" && sudo docker compose down)
  if (( PURGE_DATA == 1 )); then
    (cd "$HARBOR_DIR" && sudo docker compose down -v)
    sudo rm -rf -- "$HARBOR_DIR"
    printf 'Purged Harbor installation and data directory: %s\n' "$HARBOR_DIR"
  else
    printf 'Preserved Harbor data, credentials, certificates, and installation files.\n'
  fi
}

stop_cache() {
  if [[ -f "$CACHE_COMPOSE_FILE" && -f "$CACHE_ENV_FILE" ]]; then
    docker compose --env-file "$CACHE_ENV_FILE" -f "$CACHE_COMPOSE_FILE" down
  else
    # Keep uninstall useful if the runtime files were moved, while limiting
    # the fallback to this project's uniquely named cache container.
    docker rm -f "$CACHE_CONTAINER" >/dev/null 2>&1 || true
  fi

  if (( PURGE_DATA == 1 )); then
    docker volume rm "$CACHE_VOLUME" >/dev/null 2>&1 || true
    rm -rf -- "$CACHE_DIR"
    printf 'Purged Docker Hub cache volume and runtime files: %s\n' "$CACHE_VOLUME"
    printf 'Preserved host Nginx/TLS files; review them before reusing the hostname.\n'
  else
    printf 'Preserved Docker Hub cache volume, credentials, runtime files, and host Nginx/TLS files.\n'
  fi
}

case "$TARGET" in
  api) stop_api ;;
  harbor) stop_harbor ;;
  cache) stop_cache ;;
  all) stop_harbor; stop_cache; stop_api ;;
esac
