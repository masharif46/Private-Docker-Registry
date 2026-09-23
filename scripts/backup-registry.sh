#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VOLUME_NAME="${REGISTRY_VOLUME:-private-docker-registry-data}"
BACKUP_DIR="${BACKUP_DIR:-$ROOT_DIR/backups}"
BACKUP_FILE="${1:-$BACKUP_DIR/registry-$(date -u +%Y%m%dT%H%M%SZ).tar.gz}"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || die 'Required command not found: docker'
command -v sha256sum >/dev/null 2>&1 || die 'Required command not found: sha256sum'
mkdir -p "$BACKUP_DIR"
backup_dir="$(cd -- "$(dirname -- "$BACKUP_FILE")" && pwd)"
backup_name="$(basename -- "$BACKUP_FILE")"
host_uid="$(id -u)"
host_gid="$(id -g)"

if docker ps --format '{{.Names}}' | grep -qx 'private-docker-registry'; then
  printf '%s\n' 'The registry is running. Registry blobs are immutable, but stop the service for the most consistent backup.' >&2
fi

docker run --rm \
  --user "$host_uid:$host_gid" \
  -v "$VOLUME_NAME:/data:ro" \
  -v "$backup_dir:/backup" \
  alpine:3.22 tar czf "/backup/$backup_name" -C /data .
chmod 600 "$BACKUP_FILE"
(
  cd "$backup_dir"
  sha256sum "$backup_name" > "$backup_name.sha256"
)
chmod 600 "$BACKUP_FILE.sha256"
printf 'Created backup: %s\n' "$BACKUP_FILE"
printf 'Created checksum: %s\n' "$BACKUP_FILE.sha256"
