#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
HARBOR_VERSION="${HARBOR_VERSION:-2.15.2}"
HARBOR_DIR="${HARBOR_DIR:-$ROOT_DIR/harbor}"
HARBOR_URL="https://github.com/goharbor/harbor/releases/download/v${HARBOR_VERSION}/harbor-online-installer-v${HARBOR_VERSION}.tgz"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

install_api_registry() {
  "$ROOT_DIR/scripts/registry.sh" init
  "$ROOT_DIR/scripts/registry.sh" up
  "$ROOT_DIR/scripts/registry.sh" doctor
}

configure_harbor_yaml() {
  local file="$1" hostname="$2" admin_password="$3" database_password="$4" certificate="$5" private_key="$6" https_port="$7"
  sed -i -E "s|^hostname:.*|hostname: ${hostname}|" "$file"
  sed -i -E "s|^harbor_admin_password:.*|harbor_admin_password: ${admin_password}|" "$file"
  sed -i -E "s|^  password:.*|  password: ${database_password}|" "$file"
  sed -i -E 's|^# https:|https:|; s|^#   port:|  port:|; s|^#   certificate:|  certificate:|; s|^#   private_key:|  private_key:|' "$file"
  sed -i -E "/^http:/,/^https:/ s|^  port:.*|  port: 8080|; /^https:/,/^[^ ]/ s|^  port:.*|  port: ${https_port}|" "$file"
  sed -i -E "0,/^  certificate:/s|^  certificate:.*|  certificate: ${certificate}|; 0,/^  private_key:/s|^  private_key:.*|  private_key: ${private_key}|" "$file"
  sed -i -E "s|^data_volume:.*|data_volume: ${HARBOR_DIR}/data|" "$file"
}

install_harbor_gui() {
  local hostname admin_password database_password certificate private_key archive work_dir tls_choice https_port existing_registry credentials_file
  need docker
  need curl
  need tar
  need openssl
  docker info >/dev/null 2>&1 || die 'Docker daemon is not available.'
  existing_registry=false
  if docker inspect private-docker-registry >/dev/null 2>&1 || docker volume inspect private-docker-registry-data >/dev/null 2>&1; then
    existing_registry=true
    printf '%s\n' 'Existing lightweight registry detected. Harbor will be installed side-by-side with separate data and ports; existing images will not be changed.'
  fi
  [[ ! -e "$HARBOR_DIR" ]] || die "Harbor directory already exists: $HARBOR_DIR. Review it manually; nothing was changed."

  base_host="${REGISTRY_HOST:-registry.example.com}"
  hostname="${HARBOR_HOST:-harbor.${base_host#*.}}"
  if [[ -z "${HARBOR_HOST:-}" && -t 0 ]]; then read -r -p "Harbor public hostname [${hostname}]: " entered_hostname; hostname="${entered_hostname:-$hostname}"; fi
  [[ "$hostname" != */* && "$hostname" != *:* ]] || die 'Harbor hostname must be a DNS name without a scheme or port.'
  admin_password="${HARBOR_ADMIN_PASSWORD:-}"
  if [[ -z "$admin_password" ]]; then
    read -r -s -p 'Harbor admin password: ' admin_password; printf '\n'
    read -r -s -p 'Repeat Harbor admin password: ' entered_password; printf '\n'
    [[ "$admin_password" == "$entered_password" ]] || die 'Admin passwords do not match.'
  fi
  database_password="${HARBOR_DATABASE_PASSWORD:-}"
  if [[ -z "$database_password" ]]; then read -r -s -p 'Harbor database password: ' database_password; printf '\n'; fi
  [[ -n "$admin_password" ]] || die 'Admin password cannot be empty.'
  [[ -n "$database_password" ]] || die 'Database password cannot be empty.'
  if [[ "$existing_registry" == true ]]; then https_port="${HARBOR_HTTPS_PORT:-8443}"; else https_port="${HARBOR_HTTPS_PORT:-443}"; fi

  printf '%s\n' 'Harbor HTTPS certificate options:'
  printf '%s\n' '  1) Use existing trusted certificate and private key (recommended for production)'
  printf '%s\n' '  2) Generate a self-signed certificate (lab/testing only)'
  tls_choice="${HARBOR_TLS_MODE:-}"
  if [[ -z "$tls_choice" && -t 0 ]]; then read -r -p 'Choose [1]: ' tls_choice; fi
  tls_choice="${tls_choice:-1}"
  [[ "$existing_registry" == true && -z "${HARBOR_TLS_MODE:-}" ]] && tls_choice=2
  mkdir -p "$HARBOR_DIR"
  archive="$HARBOR_DIR/harbor-online-installer-v${HARBOR_VERSION}.tgz"
  work_dir="$HARBOR_DIR/.installer"
  mkdir -p "$work_dir"
  printf 'Downloading Harbor %s from the official release URL...\n' "$HARBOR_VERSION"
  curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$HARBOR_URL"
  tar -xzf "$archive" -C "$work_dir" --strip-components=1
  cp "$work_dir/harbor.yml.tmpl" "$HARBOR_DIR/harbor.yml"

  if [[ "$tls_choice" == 2 ]]; then
    certificate="$HARBOR_DIR/certs/harbor.crt"
    private_key="$HARBOR_DIR/certs/harbor.key"
    mkdir -p "$HARBOR_DIR/certs"
    openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days 825 \
      -keyout "$private_key" -out "$certificate" \
      -subj "/CN=${hostname}" -addext "subjectAltName=DNS:${hostname}" >/dev/null 2>&1
    chmod 600 "$private_key"
    printf '%s\n' 'Generated a self-signed Harbor certificate for lab/testing use.'
  else
    read -r -p 'Certificate path: ' certificate
    read -r -p 'Private key path: ' private_key
    [[ -s "$certificate" && -s "$private_key" ]] || die 'Certificate or private key file does not exist.'
  fi

  configure_harbor_yaml "$HARBOR_DIR/harbor.yml" "$hostname" "$admin_password" "$database_password" "$certificate" "$private_key" "$https_port"
  cp -a "$work_dir/." "$HARBOR_DIR/"
  # Avoid collisions with unrelated containers that use generic names such as
  # redis, registry, or nginx on the same Docker host.
  sed -i -E \
    -e 's|^    container_name: harbor-log$|    container_name: private-harbor-log|' \
    -e 's|^    container_name: registry$|    container_name: private-harbor-registry|' \
    -e 's|^    container_name: registryctl$|    container_name: private-harbor-registryctl|' \
    -e 's|^    container_name: harbor-db$|    container_name: private-harbor-db|' \
    -e 's|^    container_name: harbor-core$|    container_name: private-harbor-core|' \
    -e 's|^    container_name: harbor-portal$|    container_name: private-harbor-portal|' \
    -e 's|^    container_name: harbor-jobservice$|    container_name: private-harbor-jobservice|' \
    -e 's|^    container_name: redis$|    container_name: private-harbor-redis|' \
    -e 's|^    container_name: nginx$|    container_name: private-harbor-nginx|' \
    -e 's|^    container_name: trivy-adapter$|    container_name: private-harbor-trivy-adapter|' \
    "$HARBOR_DIR/docker-compose.yml"
  if [[ "$https_port" != 443 ]]; then
    sed -i -E "/^[[:space:]]*-[[:space:]]+[0-9]+:8080$/d; s|^[[:space:]]*- 443:8443$|      - ${https_port}:8443|" "$HARBOR_DIR/docker-compose.yml"
  fi
  credentials_file="$HARBOR_DIR/harbor-credentials.txt"
  umask 077
  {
    printf 'Harbor URL: https://%s:%s\n' "$hostname" "$https_port"
    printf 'Username: admin\nPassword: %s\n' "$admin_password"
    printf 'Database password: %s\n' "$database_password"
  } > "$credentials_file"
  (cd "$HARBOR_DIR" && ./prepare && ./install.sh --with-trivy)
  printf '\nHarbor GUI is available at: https://%s:%s\n' "$hostname" "$https_port"
  printf '%s\n' 'Default username: admin'
  printf 'Credentials were saved with mode 600 to: %s\n' "$credentials_file"
}

need docker
docker compose version >/dev/null 2>&1 || die 'Docker Compose v2 plugin is required.'

mode="${1:-}"
if [[ -z "$mode" ]]; then
  printf '%s\n' 'Choose registry deployment:'
  printf '%s\n' '  1) Lightweight CNCF Registry API (current project)'
  printf '%s\n' '  2) Harbor GUI (web portal, projects, RBAC, scanning, replication)'
  read -r -p 'Choose [1]: ' mode
  mode="${mode:-1}"
fi

case "$mode" in
  1|api|api-only) install_api_registry ;;
  2|harbor|gui) install_harbor_gui ;;
  *) die 'Choose 1 for API-only or 2 for Harbor GUI.' ;;
esac
