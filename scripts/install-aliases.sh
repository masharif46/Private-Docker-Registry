#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
shell_name="${SHELL##*/}"

case "$shell_name" in
  bash) shell_rc="${BASH_RC_FILE:-$HOME/.bashrc}" ;;
  zsh) shell_rc="${ZSH_RC_FILE:-$HOME/.zshrc}" ;;
  *)
    printf 'Unsupported shell: %s. Set BASH_RC_FILE or ZSH_RC_FILE and run again.\n' "$shell_name" >&2
    exit 1
    ;;
esac

marker_start="# >>> private-docker-registry aliases >>>"
marker_end="# <<< private-docker-registry aliases <<<"
mkdir -p "$(dirname -- "$shell_rc")"

if [[ -f "$shell_rc" ]] && grep -Fq "$marker_start" "$shell_rc"; then
  printf 'Registry aliases already exist in %s\n' "$shell_rc"
  exit 0
fi

cat >> "$shell_rc" <<EOF

$marker_start
export REGISTRY_DIR="$ROOT_DIR"
alias registry='"\$REGISTRY_DIR/scripts/registry.sh"'
alias registry-push='"\$REGISTRY_DIR/scripts/push-images.sh"'
alias registry-backup='"\$REGISTRY_DIR/scripts/backup-registry.sh"'
$marker_end
EOF

printf 'Added registry aliases to %s\n' "$shell_rc"
printf 'Reload with: source %s\n' "$shell_rc"
