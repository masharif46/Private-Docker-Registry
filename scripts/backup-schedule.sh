#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE="${REGISTRY_BACKUP_SCHEDULE:-0 2 * * *}"
MARKER="# private-docker-registry-backup"
CRON_COMMAND="cd '$ROOT_DIR' && '$ROOT_DIR/scripts/backup-registry.sh' $MARKER"

usage() {
  printf '%s\n' "Usage: $0 {status|install|remove [--confirm]}"
}

current_cron() { crontab -l 2>/dev/null || true; }

case "${1:-}" in
  status)
    current_cron | grep -F "$MARKER" || printf 'Backup schedule is not installed.\n'
    ;;
  install)
    command -v crontab >/dev/null 2>&1 || { printf 'Error: crontab is required.\n' >&2; exit 1; }
    existing="$(current_cron | grep -vF "$MARKER" || true)"
    { [[ -n "$existing" ]] && printf '%s\n' "$existing"; printf '%s %s\n' "$SCHEDULE" "$CRON_COMMAND"; } | crontab -
    printf 'Installed backup schedule: %s\n' "$SCHEDULE"
    ;;
  remove)
    [[ "${2:-}" == --confirm ]] || { printf 'Removal requires --confirm.\n' >&2; exit 1; }
    command -v crontab >/dev/null 2>&1 || { printf 'Error: crontab is required.\n' >&2; exit 1; }
    current_cron | grep -vF "$MARKER" | crontab -
    printf 'Removed registry backup schedule. Existing backups were preserved.\n'
    ;;
  *) usage; exit 2 ;;
esac
