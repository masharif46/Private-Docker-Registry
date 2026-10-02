#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="$ROOT_DIR/dockerhub-cache"
CACHE_COMPOSE="$ROOT_DIR/deploy/dockerhub-cache/docker-compose.yml"
ENV_FILE="${ENV_FILE:-$CACHE_DIR/.env}"
CREDENTIALS_FILE="$CACHE_DIR/credentials.txt"
NGINX_TEMPLATE="$ROOT_DIR/deploy/dockerhub-cache/nginx.conf.example"
NGINX_CONFIG_FILE="$CACHE_DIR/nginx.conf"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

usage() {
  cat <<'USAGE'
Usage: scripts/install-dockerhub-cache.sh [--check|--up]

Creates a separate Docker Hub pull-through cache:
  container: private-dockerhub-cache
  volume:    private-dockerhub-cache-data
  backend:   127.0.0.1:5002

The installer never changes or removes the existing API registry or Harbor.
USAGE
}

ACTION="${1:---check}"
case "$ACTION" in
  --check|--up) ;;
  --help|-h) usage; exit 0 ;;
  *) die "Unknown option: $ACTION" ;;
esac

need_command docker
need_command openssl
docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 plugin is required: docker compose'
mkdir -p "$CACHE_DIR/auth"
chmod 700 "$CACHE_DIR" "$CACHE_DIR/auth"

load_or_prompt() {
  local env_was_present=0
  if [[ -f "$ENV_FILE" ]]; then
    env_was_present=1
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
  DOCKERHUB_CACHE_HOST="${DOCKERHUB_CACHE_HOST:-}"
  DOCKERHUB_CACHE_PORT="${DOCKERHUB_CACHE_PORT:-5002}"
  DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
  DOCKERHUB_PASSWORD="${DOCKERHUB_PASSWORD:-}"
  if [[ -t 0 ]]; then
    if (( env_was_present == 0 )) || [[ -z "$DOCKERHUB_CACHE_HOST" ]]; then
      read -r -p "Cache hostname [${DOCKERHUB_CACHE_HOST:-dockerhub-cache.example.com}]: " entered_host
      DOCKERHUB_CACHE_HOST="${entered_host:-${DOCKERHUB_CACHE_HOST:-dockerhub-cache.example.com}}"
    fi
    if (( env_was_present == 0 )) || [[ -z "${DOCKERHUB_CACHE_PORT:-}" ]]; then
      read -r -p "Cache backend port [${DOCKERHUB_CACHE_PORT:-5002}]: " entered_port
      DOCKERHUB_CACHE_PORT="${entered_port:-${DOCKERHUB_CACHE_PORT:-5002}}"
    fi
    if (( env_was_present == 0 )); then
      read -r -p 'Docker Hub username (optional): ' entered_user
      DOCKERHUB_USERNAME="${entered_user:-$DOCKERHUB_USERNAME}"
      if [[ -n "$DOCKERHUB_USERNAME" ]]; then
        read -r -s -p 'Docker Hub password/token: ' entered_password; printf '\n'
        DOCKERHUB_PASSWORD="${entered_password:-$DOCKERHUB_PASSWORD}"
      fi
    fi
  fi
  [[ "$DOCKERHUB_CACHE_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die 'Cache hostname is invalid.'
  [[ "$DOCKERHUB_CACHE_PORT" =~ ^[0-9]+$ ]] || die 'Cache port must be numeric.'
}

write_env() {
  umask 077
  cat > "$ENV_FILE" <<EOF
DOCKERHUB_CACHE_HOST=$DOCKERHUB_CACHE_HOST
DOCKERHUB_CACHE_PORT=$DOCKERHUB_CACHE_PORT
DOCKERHUB_USERNAME=$DOCKERHUB_USERNAME
DOCKERHUB_PASSWORD=$DOCKERHUB_PASSWORD
EOF
  chmod 600 "$ENV_FILE"
}

write_config() {
  cat > "$CACHE_DIR/config.yml" <<EOF
version: 0.1
log:
  level: info
storage:
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true
http:
  addr: 0.0.0.0:5000
  debug:
    addr: 0.0.0.0:5001
auth:
  htpasswd:
    realm: Docker Hub Cache
    path: /auth/htpasswd
proxy:
  remoteurl: https://registry-1.docker.io
EOF
  if [[ -n "$DOCKERHUB_USERNAME" ]]; then
    cat >> "$CACHE_DIR/config.yml" <<EOF
  username: $DOCKERHUB_USERNAME
  password: $DOCKERHUB_PASSWORD
EOF
  fi
}

write_nginx_config() {
  sed "s/dockerhub-cache\.example\.com/$DOCKERHUB_CACHE_HOST/g" \
    "$NGINX_TEMPLATE" > "$NGINX_CONFIG_FILE"
  chmod 644 "$NGINX_CONFIG_FILE"
}

write_auth() {
  if [[ ! -s "$CACHE_DIR/auth/htpasswd" ]]; then
    [[ -n "${CACHE_USERNAME:-}" && -n "${CACHE_PASSWORD:-}" ]] || {
      if [[ -t 0 ]]; then
        read -r -p 'Cache access username [cache-reader]: ' CACHE_USERNAME
        CACHE_USERNAME="${CACHE_USERNAME:-cache-reader}"
        read -r -s -p 'Cache access password: ' CACHE_PASSWORD; printf '\n'
      else
        die 'Set CACHE_USERNAME and CACHE_PASSWORD for non-interactive installation.'
      fi
    }
    docker run --rm --entrypoint htpasswd httpd:2-alpine -Bbn \
      "$CACHE_USERNAME" "$CACHE_PASSWORD" > "$CACHE_DIR/auth/htpasswd"
    chmod 600 "$CACHE_DIR/auth/htpasswd"
    umask 077
    cat > "$CREDENTIALS_FILE" <<EOF
Cache hostname: $DOCKERHUB_CACHE_HOST
Username: $CACHE_USERNAME
Password: $CACHE_PASSWORD
EOF
    chmod 600 "$CREDENTIALS_FILE"
  fi
}

load_or_prompt
write_env
write_config
write_nginx_config
write_auth

docker compose --env-file "$ENV_FILE" -f "$CACHE_COMPOSE" config -q
printf 'Docker Hub cache configuration is valid.\n'
printf 'Container: private-dockerhub-cache\nBackend: 127.0.0.1:%s\nHostname: %s\n' "$DOCKERHUB_CACHE_PORT" "$DOCKERHUB_CACHE_HOST"
printf 'Generated Nginx config: %s\n' "$NGINX_CONFIG_FILE"
printf 'Tracked Nginx template: %s\n' "$NGINX_TEMPLATE"

if [[ "$ACTION" == --up ]]; then
  docker compose --env-file "$ENV_FILE" -f "$CACHE_COMPOSE" up -d
  docker compose --env-file "$ENV_FILE" -f "$CACHE_COMPOSE" ps
fi
