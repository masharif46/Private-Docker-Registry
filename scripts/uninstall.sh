#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HARBOR_DIR="${HARBOR_DIR:-$ROOT_DIR/harbor}"
PURGE_DATA=0
CONFIRM=0

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: scripts/uninstall.sh {api|harbor|all} [--purge-data --confirm]

Default behavior stops/removes containers but preserves registry images,
Harbor data, credentials, certificates, and Docker volumes.
EOF
}

for argument in "$@"; do
  case "$argument" in
    --purge-data) PURGE_DATA=1 ;;
    --confirm) CONFIRM=1 ;;
    -h|--help) usage; exit 0 ;;
    api|harbor|all) [[ -z "${TARGET:-}" ]] || die 'Choose only one target: api, harbor, or all.'; TARGET="$argument" ;;
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

case "$TARGET" in
  api) stop_api ;;
  harbor) stop_harbor ;;
  all) stop_harbor; stop_api ;;
esac
