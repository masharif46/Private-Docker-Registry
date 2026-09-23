#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BACKUP_FILE="${1:-}"
VOLUME_NAME="${REGISTRY_VOLUME:-private-docker-registry-data}"
REGISTRY_CONTAINER_NAME="${REGISTRY_CONTAINER_NAME:-private-docker-registry}"
FORCE_NONEMPTY=false
[[ "${3:-}" == "--force-nonempty" ]] && FORCE_NONEMPTY=true

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ -n "$BACKUP_FILE" ]] || die "Usage: $0 BACKUP_FILE --confirm [--force-nonempty]"
[[ "${2:-}" == "--confirm" ]] || die 'Restoring can overwrite files in the registry volume. Add --confirm.'
[[ -f "$BACKUP_FILE" ]] || die "Backup not found: $BACKUP_FILE"
command -v docker >/dev/null 2>&1 || die 'Required command not found: docker'
command -v sha256sum >/dev/null 2>&1 || die 'Required command not found: sha256sum'

if docker ps --format '{{.Names}}' | grep -qx "$REGISTRY_CONTAINER_NAME"; then
  die 'Stop the registry first with ./scripts/registry.sh down; no changes were made.'
fi

docker volume create "$VOLUME_NAME" >/dev/null
backup_dir="$(cd -- "$(dirname -- "$BACKUP_FILE")" && pwd)"
backup_name="$(basename -- "$BACKUP_FILE")"

if [[ -f "$BACKUP_FILE.sha256" ]]; then
  (cd "$backup_dir" && sha256sum --check "$backup_name.sha256")
else
  die "Checksum not found: $BACKUP_FILE.sha256"
fi

if ! docker run --rm -v "$VOLUME_NAME:/data:ro" alpine:3.22 \
  sh -c '[ -z "$(find /data -mindepth 1 -print -quit)" ]' 2>/dev/null; then
  $FORCE_NONEMPTY || die 'Target volume is not empty. Use a new volume, or add --force-nonempty to overlay files.'
  printf 'Warning: restoring over non-empty volume %s; existing files are not removed.\n' "$VOLUME_NAME" >&2
fi

docker run --rm \
  -v "$VOLUME_NAME:/data" \
  -v "$backup_dir:/backup:ro" \
  alpine:3.22 sh -c 'tar tzf "/backup/$1" >/dev/null && tar xzf "/backup/$1" -C /data' sh "$backup_name"

if tar tzf "$BACKUP_FILE" | grep -q '^\./docker/registry/'; then
  docker run --rm -v "$VOLUME_NAME:/data:ro" alpine:3.22 \
    test -d /data/docker/registry || die 'Post-restore verification failed: registry data directory is missing.'
fi
printf 'Restored %s into volume %s\n' "$BACKUP_FILE" "$VOLUME_NAME"
