#!/usr/bin/env bash
set -Eeuo pipefail

declare -A ssh_port_set=()

add_ssh_port() {
  local port="$1"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    printf 'Error: invalid SSH port detected or supplied: %s\n' "$port" >&2
    exit 2
  fi
  ssh_port_set["$port"]=1
}

# Explicit override supports comma- or space-separated ports.
if [[ -n "${SSH_PORTS:-}" ]]; then
  IFS=', ' read -r -a supplied_ssh_ports <<< "$SSH_PORTS"
  for port in "${supplied_ssh_ports[@]}"; do
    [[ -n "$port" ]] && add_ssh_port "$port"
  done
elif [[ -n "${SSH_PORT:-}" ]]; then
  add_ssh_port "$SSH_PORT"
fi

# Preserve the server-side port of the active SSH session.
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  read -r _ _ _ active_ssh_port <<< "$SSH_CONNECTION"
  [[ -n "${active_ssh_port:-}" ]] && add_ssh_port "$active_ssh_port"
fi

# Read all effective ports from OpenSSH, including Include files and defaults.
sshd_bin="$(command -v sshd 2>/dev/null || true)"
[[ -n "$sshd_bin" ]] || [[ ! -x /usr/sbin/sshd ]] || sshd_bin=/usr/sbin/sshd
if [[ -n "$sshd_bin" ]]; then
  while IFS= read -r configured_port; do
    [[ -n "$configured_port" ]] && add_ssh_port "$configured_port"
  done < <("$sshd_bin" -T 2>/dev/null | awk '$1 == "port" {print $2}')
fi

if (( ${#ssh_port_set[@]} == 0 )); then
  printf '%s\n' 'Error: unable to verify an active or configured SSH port.' >&2
  printf '%s\n' 'Supply it explicitly, for example: SSH_PORTS=2222 sudo -E ./scripts/firewall.sh --apply' >&2
  exit 1
fi

mapfile -t ssh_ports < <(printf '%s\n' "${!ssh_port_set[@]}" | sort -n)
printf 'Verified SSH port(s): %s\n' "${ssh_ports[*]}"

if [[ "${1:-}" != "--apply" ]]; then
  printf '%s\n' 'Dry run. No firewall rules were changed.'
  printf '%s\n' 'The apply operation allows all verified SSH ports, HTTP, and HTTPS before enabling deny-by-default incoming policy.'
  printf '%s\n' 'Apply with: sudo -E ./scripts/firewall.sh --apply'
  exit 0
fi

command -v ufw >/dev/null 2>&1 || { printf 'Error: ufw is required\n' >&2; exit 1; }

if (( EUID == 0 )); then
  UFW=(ufw)
else
  UFW=(sudo ufw)
fi

# Add access rules before changing defaults or enabling UFW to prevent lockout.
for port in "${ssh_ports[@]}"; do
  "${UFW[@]}" allow "$port/tcp" comment 'SSH'
done
"${UFW[@]}" allow 80/tcp comment 'HTTP for ACME and redirects'
"${UFW[@]}" allow 443/tcp comment 'HTTPS registry'
"${UFW[@]}" default deny incoming
"${UFW[@]}" default allow outgoing
"${UFW[@]}" --force enable
"${UFW[@]}" status verbose
