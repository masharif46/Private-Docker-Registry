#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TARGET="${1:-}"
REMOTE_DIR="${2:-/opt/private-docker-registry}"
[[ -n "$TARGET" ]] || { printf 'Usage: %s user@new-vps /opt/private-docker-registry\n' "$0" >&2; exit 2; }
[[ "$REMOTE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || { printf 'Error: remote directory must be an absolute path containing only letters, numbers, dots, underscores, dashes, and slashes.\n' >&2; exit 2; }
command -v ssh >/dev/null 2>&1 || { printf 'Error: ssh is required\n' >&2; exit 1; }
command -v scp >/dev/null 2>&1 || { printf 'Error: scp is required\n' >&2; exit 1; }
if docker ps --format '{{.Names}}' | grep -qx 'private-docker-registry'; then
  printf 'Error: stop the source registry before migration for a consistent backup.\n' >&2
  exit 1
fi

backup_file="$(mktemp "${TMPDIR:-/tmp}/registry-migration.XXXXXX.tar.gz")"
cleanup() { rm -f -- "$backup_file" "$backup_file.sha256"; }
trap cleanup EXIT
"$ROOT_DIR/scripts/backup-registry.sh" "$backup_file"

# REMOTE_DIR is restricted to a safe absolute-path character set above.
# shellcheck disable=SC2029
ssh "$TARGET" "mkdir -p '$REMOTE_DIR/registry/auth' '$REMOTE_DIR/registry/certs' '$REMOTE_DIR/backups'"
scp "$backup_file" "$TARGET:$REMOTE_DIR/backups/$(basename "$backup_file")"
scp "$backup_file.sha256" "$TARGET:$REMOTE_DIR/backups/$(basename "$backup_file").sha256"
scp .env "$TARGET:$REMOTE_DIR/.env"
scp -r registry/auth registry/certs "$TARGET:$REMOTE_DIR/registry/"
# shellcheck disable=SC2029
ssh "$TARGET" "chmod 600 '$REMOTE_DIR/.env' '$REMOTE_DIR/backups/$(basename "$backup_file")' '$REMOTE_DIR/backups/$(basename "$backup_file").sha256'; cd '$REMOTE_DIR' && ./scripts/restore-registry.sh 'backups/$(basename "$backup_file")' --confirm"
printf 'Copied registry data and private configuration to %s:%s\n' "$TARGET" "$REMOTE_DIR"
printf 'Clone this repository on the new VPS, then run: ./scripts/registry.sh up\n'
