#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="$ROOT_DIR/dockerhub-cache"
AUTH_DIR="$CACHE_DIR/auth"
AUTH_FILE="$AUTH_DIR/htpasswd"
ENV_FILE="$CACHE_DIR/.env"
COMPOSE_FILE="$ROOT_DIR/deploy/dockerhub-cache/docker-compose.yml"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/dockerhub-cache.sh COMMAND [ARGS]

Commands:
  up                         Start or create the Docker Hub cache
  down                       Stop the Docker Hub cache; preserve cached layers
  restart                    Restart the Docker Hub cache
  status                     Show cache service status
  logs [ARGS...]             Show cache logs
  user list                  List cache usernames
  user add USER              Add a cache user (prompts for password)
  user password USER         Change a user's password (prompts securely)
  user remove USER --confirm Remove a cache user

User commands require cache authentication to be enabled.
EOF
}

load_compose() {
  [[ -f "$ENV_FILE" ]] || die "Cache configuration not found: $ENV_FILE (run scripts/install-dockerhub-cache.sh first)."
  COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
}

prepare_auth() {
  load_compose
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  [[ "${CACHE_AUTH_ENABLED:-true}" == true ]] || die 'Cache authentication is disabled. Re-enable it with scripts/install-dockerhub-cache.sh --up --auth.'
  [[ -f "$AUTH_FILE" ]] || die "Cache user file not found: $AUTH_FILE (run scripts/install-dockerhub-cache.sh --up --auth first)."
  if [[ "$EUID" -eq 0 ]]; then
    chown "$(id -u):$(id -g)" "$AUTH_DIR" "$AUTH_FILE"
  elif [[ "$(stat -c '%u' "$AUTH_FILE")" != "$(id -u)" || "$(stat -c '%u' "$AUTH_DIR")" != "$(id -u)" ]]; then
    command -v sudo >/dev/null 2>&1 || die 'Cache user file is owned by another user; use sudo to change its ownership first.'
    sudo chown "$(id -u):$(id -g)" "$AUTH_DIR" "$AUTH_FILE"
  fi
  chmod 700 "$AUTH_DIR"
  chmod 600 "$AUTH_FILE"
}

validate_user() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]] || die 'Username must contain only letters, numbers, dots, underscores, or dashes.'
}

backup_auth() {
  local backup="$AUTH_FILE.$(date -u +%Y%m%dT%H%M%SZ).bak"
  cp -p "$AUTH_FILE" "$backup"
  chmod 600 "$backup"
  printf 'Backed up cache users to %s\n' "$backup"
}

user_command() {
  local action="${1:-}" username="${2:-}" uid_gid
  prepare_auth
  case "$action" in
    list)
      cut -d: -f1 "$AUTH_FILE"
      ;;
    add|password)
      validate_user "$username"
      if [[ "$action" == add && -n "$(awk -F: -v user="$username" '$1 == user {print $1}' "$AUTH_FILE")" ]]; then
        die "Cache user already exists: $username (use 'user password $username' to change its password)."
      fi
      if [[ "$action" == password && -z "$(awk -F: -v user="$username" '$1 == user {print $1}' "$AUTH_FILE")" ]]; then
        die "Cache user does not exist: $username (use 'user add $username' to add it)."
      fi
      [[ -t 0 ]] || die 'User creation and password changes require an interactive terminal.'
      backup_auth
      uid_gid="$(id -u):$(id -g)"
      docker run --rm -it --user "$uid_gid" \
        --entrypoint htpasswd \
        -v "$AUTH_DIR:/auth" \
        httpd:2-alpine \
        -B /auth/htpasswd "$username"
      chmod 600 "$AUTH_FILE"
      printf 'Cache user %s %s. Run scripts/dockerhub-cache.sh restart to load the change.\n' \
        "$username" "$([[ "$action" == add ]] && printf 'added' || printf 'password updated')"
      ;;
    remove)
      validate_user "$username"
      [[ "${3:-}" == --confirm ]] || die 'User removal requires: scripts/dockerhub-cache.sh user remove USER --confirm'
      awk -F: -v user="$username" '$1 == user {found=1} END {exit !found}' "$AUTH_FILE" || die "Cache user does not exist: $username"
      [[ "$(awk -F: -v user="$username" '$1 != user {count++} END {print count+0}' "$AUTH_FILE")" -gt 0 ]] || die 'Cannot remove the last cache user. Add another user or disable cache authentication instead.'
      backup_auth
      local temp
      temp="$(mktemp "$AUTH_DIR/.htpasswd.XXXXXX")"
      awk -F: -v user="$username" '$1 != user' "$AUTH_FILE" > "$temp"
      chmod 600 "$temp"
      mv "$temp" "$AUTH_FILE"
      printf 'Removed cache user %s. Run scripts/dockerhub-cache.sh restart to load the change.\n' "$username"
      ;;
    *) die 'Usage: scripts/dockerhub-cache.sh user {list|add USER|password USER|remove USER --confirm}' ;;
  esac
}

command_name="${1:-}"
shift || true
case "$command_name" in
  --help|-h|help) usage ;;
  up) load_compose; "${COMPOSE[@]}" up -d ;;
  down) load_compose; "${COMPOSE[@]}" down ;;
  restart) load_compose; "${COMPOSE[@]}" restart cache ;;
  status) load_compose; "${COMPOSE[@]}" ps cache ;;
  logs) load_compose; "${COMPOSE[@]}" logs "$@" ;;
  user) user_command "$@" ;;
  *) usage >&2; exit 2 ;;
esac
