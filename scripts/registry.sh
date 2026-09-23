#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="${ENV_FILE:-.env}"
REGISTRY_OVERRIDE=""
JSON_OUTPUT=0
QUIET=0
DRY_RUN=0
CONFIRM=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --env-file) [[ -n "${2:-}" ]] || { printf 'Error: --env-file requires a path.\n' >&2; exit 2; }; ENV_FILE="$2"; shift 2 ;;
    --registry) [[ -n "${2:-}" ]] || { printf 'Error: --registry requires a host.\n' >&2; exit 2; }; REGISTRY_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_OUTPUT=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --confirm) CONFIRM=1; shift ;;
    --help|-h) break ;;
    *) break ;;
  esac
done
COMPOSE=(docker compose --env-file "$ENV_FILE" -f docker-compose.yml)

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

load_env() {
  [[ -f "$ENV_FILE" ]] || die "$ENV_FILE does not exist. Run: cp .env.example .env"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  : "${REGISTRY_HOST:?REGISTRY_HOST is missing from $ENV_FILE}"
  : "${REGISTRY_USERNAME:?REGISTRY_USERNAME is missing from $ENV_FILE}"
  : "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is missing from $ENV_FILE}"
  if [[ -n "$REGISTRY_OVERRIDE" ]]; then REGISTRY_HOST="$REGISTRY_OVERRIDE"; fi
}

load_api() {
  load_env
  need_command curl
  need_command jq
  API_ROOT="https://${REGISTRY_HOST}/v2"
  CA_ARGS=()
  caddy_running="$(docker inspect private-registry-caddy --format '{{.State.Running}}' 2>/dev/null || true)"
  if [[ -n "${REGISTRY_CA_FILE:-}" && -f "$REGISTRY_CA_FILE" ]]; then
    CA_ARGS=(--cacert "$REGISTRY_CA_FILE")
  elif [[ "$caddy_running" != true && -f registry/certs/registry.crt ]]; then
    CA_ARGS=(--cacert registry/certs/registry.crt)
  fi
  AUTH_ARGS=(--user "$REGISTRY_USERNAME:$REGISTRY_PASSWORD")
}

api_request() {
  curl --fail --silent --show-error "${CA_ARGS[@]}" "${AUTH_ARGS[@]}" "$@"
}

parse_image() {
  local input="$1" path last
  if [[ "$input" == "$REGISTRY_HOST/"* ]]; then
    path="${input#"$REGISTRY_HOST/"}"
  else
    path="$input"
  fi
  [[ "$path" == */* ]] || die "Image reference must include a repository path: $input"
  if [[ "$path" == *@* ]]; then
    IMAGE_REPOSITORY="${path%@*}"
    IMAGE_REFERENCE="${path#*@}"
  else
    last="${path##*/}"
    if [[ "$last" == *:* ]]; then
      IMAGE_TAG="${last##*:}"
      IMAGE_REPOSITORY="${path%:"$IMAGE_TAG"}"
    else
      IMAGE_TAG=latest
      IMAGE_REPOSITORY="$path"
    fi
    IMAGE_REFERENCE="$IMAGE_TAG"
  fi
  [[ -n "$IMAGE_REPOSITORY" && -n "$IMAGE_REFERENCE" ]] || die "Invalid image reference: $input"
  IMAGE_API="${API_ROOT}/${IMAGE_REPOSITORY}"
  if [[ "$path" == *@* ]]; then
    IMAGE_FULL="${REGISTRY_HOST}/${IMAGE_REPOSITORY}@${IMAGE_REFERENCE}"
  else
    IMAGE_FULL="${REGISTRY_HOST}/${IMAGE_REPOSITORY}:${IMAGE_REFERENCE}"
  fi
}

init_registry() {
  load_env
  need_command openssl
  need_command docker
  mkdir -p registry/auth registry/certs
  chmod 700 registry/auth registry/certs

  if [[ ! -s registry/auth/htpasswd ]]; then
    umask 077
    docker run --rm --entrypoint htpasswd httpd:2-alpine -Bbn \
      "$REGISTRY_USERNAME" "$REGISTRY_PASSWORD" > registry/auth/htpasswd
    printf 'Created registry/auth/htpasswd\n'
  else
    printf 'Keeping existing registry/auth/htpasswd\n'
  fi

  if [[ ! -s registry/certs/registry.crt || ! -s registry/certs/registry.key ]]; then
    cert_host="${REGISTRY_HOST%%:*}"
    openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days 825 \
      -keyout registry/certs/registry.key \
      -out registry/certs/registry.crt \
      -subj "/CN=${cert_host}" \
      -addext "subjectAltName=DNS:${cert_host}" >/dev/null 2>&1
    chmod 600 registry/certs/registry.key
    printf 'Created a self-signed certificate for %s\n' "$REGISTRY_HOST"
  else
    printf 'Keeping existing registry certificate\n'
  fi
}

registry_health() {
  load_env
  need_command docker
  local health
  health="$(docker inspect private-docker-registry --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' 2>/dev/null || true)"
  printf 'container=private-docker-registry health=%s\n' "${health:-missing}"
  [[ "$health" == healthy ]]
}

docker_login() {
  load_env
  printf '%s' "$REGISTRY_PASSWORD" | docker login "$REGISTRY_HOST" --username "$REGISTRY_USERNAME" --password-stdin >/dev/null
}

registry_version() {
  load_env
  printf 'Registry image: '
  docker inspect registry:3.1.1 --format '{{.RepoTags}}' 2>/dev/null || printf 'registry:3.1.1\n'
  docker compose version
  docker version --format 'Docker client={{.Client.Version}} server={{.Server.Version}}'
}

config_validate() {
  load_env
  need_command docker
  "${COMPOSE[@]}" config -q
  printf 'Compose configuration is valid: %s\n' "$ENV_FILE"
}

doctor_registry() {
  local failures=0 health response port free_kb
  printf 'Registry doctor\n'
  for command_name in docker curl jq openssl getent df ss; do
    if command -v "$command_name" >/dev/null 2>&1; then printf 'PASS command %s\n' "$command_name"; else printf 'FAIL command %s\n' "$command_name"; failures=$((failures + 1)); fi
  done
  if [[ -f "$ENV_FILE" ]]; then
    printf 'PASS environment %s\n' "$ENV_FILE"
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  else
    printf 'FAIL environment %s\n' "$ENV_FILE"
    return 1
  fi
  for required_path in registry/auth/htpasswd registry/certs/registry.crt registry/certs/registry.key; do
    if [[ -s "$required_path" ]]; then printf 'PASS file %s\n' "$required_path"; else printf 'FAIL file %s\n' "$required_path"; failures=$((failures + 1)); fi
  done
  if docker info >/dev/null 2>&1; then printf 'PASS Docker daemon\n'; else printf 'FAIL Docker daemon\n'; failures=$((failures + 1)); fi
  if docker inspect private-docker-registry >/dev/null 2>&1; then
    health="$(docker inspect private-docker-registry --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}')"
    printf '%s container health=%s\n' "$( [[ "$health" == healthy ]] && printf PASS || printf FAIL )" "$health"
    [[ "$health" == healthy ]] || failures=$((failures + 1))
  else
    printf 'FAIL registry container\n'
    failures=$((failures + 1))
  fi
  if docker compose version >/dev/null 2>&1 && "${COMPOSE[@]}" config -q >/dev/null 2>&1; then printf 'PASS Compose configuration\n'; else printf 'FAIL Compose configuration\n'; failures=$((failures + 1)); fi
  port="${REGISTRY_PORT:-5000}"
  if ss -ltn 2>/dev/null | awk -v port=":$port" '$4 ~ port"$" {found=1} END {exit !found}'; then printf 'PASS registry port %s\n' "$port"; else printf 'FAIL registry port %s\n' "$port"; failures=$((failures + 1)); fi
  if [[ -s registry/certs/registry.crt && -s registry/certs/registry.key ]] && openssl x509 -in registry/certs/registry.crt -noout >/dev/null 2>&1; then printf 'PASS TLS certificate\n'; else printf 'FAIL TLS certificate\n'; failures=$((failures + 1)); fi
  if docker volume inspect private-docker-registry-data >/dev/null 2>&1; then printf 'PASS registry storage volume\n'; else printf 'FAIL registry storage volume\n'; failures=$((failures + 1)); fi
  free_kb="$(df -Pk . | awk 'NR==2 {print $4}')"
  if [[ "$free_kb" =~ ^[0-9]+$ ]] && (( free_kb > 1048576 )); then printf 'PASS free disk %s MiB\n' "$((free_kb / 1024))"; else printf 'WARN free disk %s KiB\n' "${free_kb:-unknown}"; fi
  if getent hosts "$REGISTRY_HOST" >/dev/null 2>&1; then printf 'PASS DNS %s\n' "$REGISTRY_HOST"; else printf 'FAIL DNS %s\n' "$REGISTRY_HOST"; failures=$((failures + 1)); fi
  response="$(curl --silent --show-error --insecure -o /dev/null -w '%{http_code}' "https://${REGISTRY_HOST}/v2/" 2>/dev/null || true)"
  if [[ "$response" == 401 || "$response" == 200 ]]; then printf 'PASS registry API HTTP %s\n' "$response"; else printf 'FAIL registry API HTTP %s\n' "${response:-unreachable}"; failures=$((failures + 1)); fi
  response="$(curl --silent --show-error --insecure -o /dev/null -w '%{http_code}' --user "$REGISTRY_USERNAME:$REGISTRY_PASSWORD" "https://${REGISTRY_HOST}/v2/" 2>/dev/null || true)"
  if [[ "$response" == 200 ]]; then printf 'PASS authentication HTTP %s\n' "$response"; else printf 'FAIL authentication HTTP %s\n' "${response:-unreachable}"; failures=$((failures + 1)); fi
  (( failures == 0 ))
}

repo_list() {
  load_api
  local result
  result="$(api_request "$API_ROOT/_catalog?n=1000")"
  if [[ "${1:-}" == "--json" || "$JSON_OUTPUT" == 1 ]]; then printf '%s\n' "$result" | jq .; else printf '%s\n' "$result" | jq -r '.repositories[]?'; fi
}

image_list() { repo_list "${1:-}"; }

repo_tags() {
  [[ -n "${1:-}" ]] || die 'Usage: registry repo tags REPOSITORY'
  load_api
  api_request "$API_ROOT/$1/tags/list" | jq .
}

image_digest() {
  parse_image "$1"
  curl --fail --silent --show-error --dump-header - --output /dev/null \
    "${CA_ARGS[@]}" "${AUTH_ARGS[@]}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
    "$IMAGE_API/manifests/$IMAGE_REFERENCE" |
    awk -F': ' 'tolower($1)=="docker-content-digest" {gsub("\r", "", $2); print $2; exit}'
}

image_exists() {
  load_api
  parse_image "$1"
  local status
  status="$(curl --silent --show-error -o /dev/null -w '%{http_code}' "${CA_ARGS[@]}" "${AUTH_ARGS[@]}" -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' "$IMAGE_API/manifests/$IMAGE_REFERENCE")"
  [[ "$status" == 200 ]] && printf 'EXISTS %s\n' "$IMAGE_FULL" && return 0
  printf 'NOT FOUND %s (HTTP %s)\n' "$IMAGE_FULL" "$status"
  return 1
}

image_inspect() {
  load_api
  parse_image "$1"
  local manifest digest
  manifest="$(api_request -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' "$IMAGE_API/manifests/$IMAGE_REFERENCE")"
  digest="$(image_digest "$1")"
  jq --arg image "$IMAGE_FULL" --arg digest "$digest" --arg repository "$IMAGE_REPOSITORY" --arg reference "$IMAGE_REFERENCE" \
    '{image:$image, repository:$repository, reference:$reference, digest:$digest, manifest:.}' <<< "$manifest"
}

image_size() {
  load_api
  parse_image "$1"
  local manifest
  manifest="$(api_request -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' "$IMAGE_API/manifests/$IMAGE_REFERENCE")"
  jq --arg image "$IMAGE_FULL" '{image:$image, manifest_size_bytes:(tojson|length), layer_size_bytes:(([.layers[]?.size] | add) // 0), config_size_bytes:(.config.size // 0)}' <<< "$manifest"
}

image_pull() {
  load_env
  [[ -n "${1:-}" ]] || die 'Usage: registry image pull IMAGE'
  local image="$1"
  [[ "$image" == "$REGISTRY_HOST/"* ]] || image="${REGISTRY_HOST}/${image}"
  docker_login
  docker pull "$image"
}

image_push() {
  load_env
  docker_login
  "$ROOT_DIR/scripts/push-images.sh" "$@"
}

image_copy() {
  load_env
  local source="${1:-}" destination="${2:-}"
  [[ -n "$source" && -n "$destination" ]] || die 'Usage: registry image copy SOURCE_IMAGE DESTINATION_IMAGE'
  [[ "$destination" == "$REGISTRY_HOST/"* ]] || destination="${REGISTRY_HOST}/${destination}"
  docker_login
  docker pull "$source"
  docker tag "$source" "$destination"
  docker push "$destination"
  printf 'Copied %s to %s\n' "$source" "$destination"
}

image_delete() {
  load_api
  [[ -n "${1:-}" ]] || die 'Usage: registry image delete IMAGE [--confirm]'
  local image="$1" confirmation="${2:-}" force_shared="${3:-}" digest tags_json tag tag_digest shared_tags=()
  [[ "$CONFIRM" == 1 ]] && confirmation=--confirm
  (( DRY_RUN )) && confirmation=--dry-run
  parse_image "$image"
  digest="$(image_digest "$image")"
  [[ -n "$digest" ]] || die "Could not resolve image digest: $image"
  (( QUIET )) || printf 'Target: %s\nDigest: %s\n' "$IMAGE_FULL" "$digest"
  [[ "$confirmation" == --confirm ]] || { printf 'Dry run only. Add --confirm to delete this manifest.\n'; return 0; }
  tags_json="$(api_request "$IMAGE_API/tags/list")"
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    tag_digest="$(image_digest "${IMAGE_REPOSITORY}:${tag}")"
    [[ "$tag_digest" == "$digest" ]] && shared_tags+=("$tag")
  done < <(jq -r '.tags[]?' <<< "$tags_json")
  if (( ${#shared_tags[@]} > 1 )) && [[ "$force_shared" != --force-shared ]]; then
    printf 'Refusing deletion: digest is shared by tags: %s\n' "${shared_tags[*]}" >&2
    printf 'If intentional, use --confirm --force-shared.\n' >&2
    return 1
  fi
  api_request -X DELETE "$IMAGE_API/manifests/$digest" >/dev/null
  printf 'Deleted manifest %s\n' "$digest"
}

backup_command() {
  case "${1:-}" in
    create) shift; "$ROOT_DIR/scripts/backup-registry.sh" "$@" ;;
    list) mkdir -p backups; find backups -maxdepth 1 -type f -name 'registry-*.tar.gz' -printf '%f\n' | sort ;;
    verify)
      [[ -n "${2:-}" ]] || die 'Usage: registry backup verify BACKUP_FILE'
      [[ -f "$2.sha256" ]] || die "Checksum not found: $2.sha256"
      (cd "$(dirname "$2")" && sha256sum --check "$(basename "$2").sha256")
      ;;
    restore) shift; "$ROOT_DIR/scripts/restore-registry.sh" "$@" ;;
    schedule) load_env; shift; "$ROOT_DIR/scripts/backup-schedule.sh" "$@" ;;
    *) printf 'Usage: registry backup {create|list|verify|restore|schedule}\n'; exit 2 ;;
  esac
}

migration_command() {
  local action="${1:-}" target="${2:-}" remote_dir="${3:-/opt/private-docker-registry}"
  [[ -n "$target" ]] || die 'Usage: registry migrate {check|plan|run|verify} user@host [/absolute/path] [--confirm]'
  [[ "$remote_dir" =~ ^/[A-Za-z0-9._/-]+$ ]] || die 'Remote directory must be a safe absolute path.'
  need_command ssh
  case "$action" in
    check)
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" true
      printf 'SSH connectivity verified: %s\n' "$target"
      ;;
    plan)
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" true
      printf 'Migration plan: create a checksummed backup, copy configuration and registry data to %s:%s, then restore it on the stopped destination.\n' "$target" "$remote_dir"
      ;;
    run)
      [[ "${4:-}" == --confirm || "$CONFIRM" == 1 ]] || die 'Migration requires: registry migrate run user@host /path --confirm'
      "$ROOT_DIR/scripts/migrate-registry.sh" "$target" "$remote_dir"
      ;;
    verify)
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" "test -f '$remote_dir/.env' && test -d '$remote_dir/registry' && test -d '$remote_dir/backups'"
      printf 'Destination layout verified: %s:%s\n' "$target" "$remote_dir"
      ;;
    *) die 'Usage: registry migrate {check|plan|run|verify} user@host [/absolute/path] [--confirm]' ;;
  esac
}

user_command() {
  local auth_file=registry/auth/htpasswd username password password_again temp
  mkdir -p registry/auth
  case "${1:-}" in
    list) [[ -f "$auth_file" ]] && cut -d: -f1 "$auth_file" || true ;;
    add|password)
      username="${2:-}"
      [[ "$username" =~ ^[A-Za-z0-9._-]+$ ]] || die 'Username must contain only letters, numbers, dots, underscores, or dashes.'
      [[ -t 0 ]] || die 'User creation requires an interactive terminal.'
      read -r -s -p "Password for $username: " password; printf '\n'
      read -r -s -p 'Repeat password: ' password_again; printf '\n'
      [[ "$password" == "$password_again" ]] || die 'Passwords do not match.'
      temp="$(mktemp)"
      umask 077
      docker run --rm --entrypoint htpasswd httpd:2-alpine -Bbn "$username" "$password" > "$temp"
      if [[ -f "$auth_file" && "$1" == add ]]; then
        awk -F: -v user="$username" '$1 != user' "$auth_file" > "${temp}.all"
        cat "$temp" >> "${temp}.all"
        mv "${temp}.all" "$auth_file"
      else
        mv "$temp" "$auth_file"
      fi
      chmod 600 "$auth_file"
      printf 'Updated %s. Restart the registry to load the change.\n' "$auth_file"
      ;;
    remove)
      username="${2:-}"
      [[ "${3:-}" == --confirm ]] || die 'User removal requires: registry user remove USER --confirm'
      [[ -f "$auth_file" ]] || die 'Authentication file does not exist.'
      temp="$(mktemp)"
      awk -F: -v user="$username" '$1 != user' "$auth_file" > "$temp"
      mv "$temp" "$auth_file"
      chmod 600 "$auth_file"
      printf 'Removed user %s. Restart the registry to load the change.\n' "$username"
      ;;
    *) printf 'Usage: registry user {list|add|password|remove}\n'; exit 2 ;;
  esac
}

storage_command() {
  if [[ "${3:-}" == --env-file ]]; then
    [[ -n "${4:-}" ]] || die '--env-file requires a path.'
    ENV_FILE="$4"
    COMPOSE=(docker compose --env-file "$ENV_FILE" -f docker-compose.yml)
  fi
  load_env
  case "${1:-}" in
    status) docker volume inspect private-docker-registry-data 2>/dev/null || true; docker system df -v ;;
    usage) docker run --rm -v private-docker-registry-data:/data:ro alpine:3.22 du -sh /data ;;
    check) docker volume inspect private-docker-registry-data >/dev/null || die 'Registry volume is missing.'; registry_health; ;;
    filesystem) [[ "${2:-}" == check ]] || die 'Usage: registry storage filesystem check'; docker run --rm -v private-docker-registry-data:/data:ro alpine:3.22 sh -c 'test -r /data && test -x /data && du -sh /data' ;;
    aws|linode)
      [[ "${2:-}" == check ]] || die "Usage: registry storage $1 check --env-file FILE"
      printf 'S3 profile %s: validating Compose configuration and endpoint reachability only; no object is uploaded.\n' "$1"
      [[ "$ENV_FILE" != .env ]] || die 'Use --env-file with the S3 profile.'
      override="docker-compose.$1-s3.yml"
      "${COMPOSE[@]}" -f "$override" config -q
      if [[ "$1" == aws ]]; then
        endpoint="https://s3.${AWS_REGION:?AWS_REGION is missing from $ENV_FILE}.amazonaws.com"
      else
        endpoint="${LINODE_S3_ENDPOINT:?LINODE_S3_ENDPOINT is missing from $ENV_FILE}"
      fi
      endpoint_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --head --max-time 15 "$endpoint" 2>/dev/null || true)"
      case "$endpoint_status" in
        2*|3*|401|403|405) printf 'S3 endpoint responded with HTTP %s; configuration is valid and no object was uploaded: %s\n' "$endpoint_status" "$endpoint" ;;
        *) die "Endpoint is unreachable: $endpoint (HTTP ${endpoint_status:-no response})" ;;
      esac
      ;;
    *) printf 'Usage: registry storage {status|usage|check}\n'; exit 2 ;;
  esac
}

retention_command() {
  local action="${1:-plan}" repository days
  if [[ "$action" == plan || "$action" == apply ]]; then shift; else action=plan; fi
  repository="${1:-}"
  if [[ "${2:-}" == --days ]]; then days="${3:-}"; else days="${2:-}"; fi
  [[ -n "$repository" && -n "$days" ]] || die 'Usage: registry retention {plan|apply} REPOSITORY --days DAYS [--confirm]'
  if [[ "$action" == apply ]]; then
    [[ "${4:-}" == --confirm || "$CONFIRM" == 1 ]] || die 'Retention apply requires --confirm.'
    "$ROOT_DIR/scripts/retention.sh" "$repository" "$days" --delete --confirm
  else
    "$ROOT_DIR/scripts/retention.sh" "$repository" "$days"
  fi
}

gc_command() {
  case "${1:-plan}" in
    plan) "$ROOT_DIR/scripts/garbage-collect.sh" ;;
    run) [[ "${2:-}" == --confirm || "$CONFIRM" == 1 ]] || die 'Garbage collection requires: registry gc run --confirm'; "$ROOT_DIR/scripts/garbage-collect.sh" --delete --confirm ;;
    --delete) "$ROOT_DIR/scripts/garbage-collect.sh" "$@" ;;
    *) die 'Usage: registry gc {plan|run --confirm}' ;;
  esac
}

tls_command() {
  case "${1:-}" in
    status|inspect|expires)
      [[ -s registry/certs/registry.crt ]] || die 'Certificate not found: registry/certs/registry.crt'
      openssl x509 -in registry/certs/registry.crt -noout -subject -issuer -dates -fingerprint -sha256
      ;;
    trust)
      [[ "${2:-}" == install ]] || die 'Usage: registry tls trust install'
      load_env
      need_command update-ca-certificates
      install_path="/usr/local/share/ca-certificates/${REGISTRY_HOST}.crt"
      if [[ "$EUID" -eq 0 ]]; then install -m 0644 registry/certs/registry.crt "$install_path"; update-ca-certificates; else sudo install -m 0644 registry/certs/registry.crt "$install_path"; sudo update-ca-certificates; fi
      printf 'Installed registry CA trust: %s\n' "$install_path"
      ;;
    self-signed)
      [[ "${2:-}" == renew ]] || die 'Usage: registry tls self-signed renew --confirm'
      [[ "${3:-}" == --confirm || "$CONFIRM" == 1 ]] || die 'Certificate renewal requires --confirm.'
      load_env
      cert_host="${REGISTRY_HOST%%:*}"
      timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
      [[ -s registry/certs/registry.crt ]] && cp -p registry/certs/registry.crt "registry/certs/registry.crt.bak.$timestamp"
      [[ -s registry/certs/registry.key ]] && cp -p registry/certs/registry.key "registry/certs/registry.key.bak.$timestamp"
      openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days 825 -keyout registry/certs/registry.key -out registry/certs/registry.crt -subj "/CN=${cert_host}" -addext "subjectAltName=DNS:${cert_host}" >/dev/null 2>&1
      chmod 600 registry/certs/registry.key
      printf 'Created a new self-signed certificate. Restart the registry and reinstall client trust if needed.\n'
      ;;
    *) printf 'Usage: registry tls {status|inspect|expires|trust install|self-signed renew --confirm}\n'; exit 2 ;;
  esac
}

monitoring_command() {
  load_env
  case "${1:-}" in
    up) "${COMPOSE[@]}" -f docker-compose.monitoring.yml up -d ;;
    down) "${COMPOSE[@]}" -f docker-compose.monitoring.yml down ;;
    status) "${COMPOSE[@]}" -f docker-compose.monitoring.yml ps ;;
    *) printf 'Usage: registry monitoring {up|down|status}\n'; exit 2 ;;
  esac
}

metrics_command() {
  case "${1:-}" in
    status) docker exec private-docker-registry wget -qO- http://127.0.0.1:5001/metrics >/dev/null && printf 'Registry metrics endpoint is available.\n' ;;
    show) docker exec private-docker-registry wget -qO- http://127.0.0.1:5001/metrics ;;
    *) printf 'Usage: registry metrics {status|show}\n'; exit 2 ;;
  esac
}

signing_command() {
  case "${1:-}" in
    sign) shift; "$ROOT_DIR/scripts/sign-image.sh" "$@" ;;
    verify) shift; "$ROOT_DIR/scripts/verify-image.sh" "$@" ;;
    *) printf 'Usage: registry image {sign|verify} IMAGE\n'; exit 2 ;;
  esac
}

firewall_command() {
  case "${1:-}" in
    check|plan) "$ROOT_DIR/scripts/firewall.sh" ;;
    apply) [[ "${2:-}" == --confirm || "$CONFIRM" == 1 ]] || die 'Firewall changes require --confirm.'; "$ROOT_DIR/scripts/firewall.sh" --apply ;;
    *) printf 'Usage: registry firewall {check|plan|apply --confirm}\n'; exit 2 ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: registry [--env-file FILE] COMMAND [SUBCOMMAND] [OPTIONS]

Lifecycle: init, up, down, restart, logs, status, login, health, doctor
Repositories: repo list [--json], repo tags REPOSITORY
Images: image inspect|exists|pull|push|delete IMAGE [--confirm] [--force-shared]
Backups: backup create|list|verify|restore|schedule
Security: user list|add|password|remove, tls status|inspect|expires|trust|self-signed
Operations: storage status|usage|check, monitoring up|down|status, metrics, firewall, gc

Examples:
  registry doctor
  registry repo list
  registry repo tags docker.io/library/nginx
  registry image list
  registry image inspect docker.io/library/nginx:1.27
  registry image digest docker.io/library/nginx:1.27
  registry image size docker.io/library/nginx:1.27
  registry image push
  registry image copy source/image:v1 team/image:v1
  registry image delete team/app:v1 --confirm
  registry image delete team/app:v1 --confirm --force-shared
  registry backup create
  registry gc --delete --confirm
EOF
}

command_name="${1:-}"
shift || true
case "$command_name" in
  --help|-h|help) usage; exit 0 ;;
  init) init_registry ;;
  up) load_env; "${COMPOSE[@]}" up -d ;;
  down) load_env; "${COMPOSE[@]}" down ;;
  restart) load_env; "${COMPOSE[@]}" restart ;;
  logs) load_env; "${COMPOSE[@]}" logs "$@" ;;
  status) load_env; "${COMPOSE[@]}" ps ;;
  version) registry_version ;;
  config) [[ "${1:-}" == validate ]] || die 'Usage: registry config validate'; config_validate ;;
  login) docker_login; printf 'Login succeeded for %s\n' "$REGISTRY_HOST" ;;
  logout) load_env; docker logout "$REGISTRY_HOST" ;;
  health) registry_health ;;
  doctor) doctor_registry ;;
  repo) case "${1:-}" in list) repo_list "${2:-}" ;; tags) repo_tags "${2:-}" ;; *) printf 'Usage: registry repo {list|tags REPOSITORY}\n'; exit 2 ;; esac ;;
  image)
    case "${1:-}" in
      list) image_list "${2:-}" ;;
      inspect) image_inspect "${2:-}" ;;
      exists) image_exists "${2:-}" ;;
      digest) load_api; image_digest "${2:-}" ;;
      size) image_size "${2:-}" ;;
      pull) image_pull "${2:-}" ;;
      push) shift; image_push "$@" ;;
      copy) image_copy "${2:-}" "${3:-}" ;;
      sign|verify) signing_command "$@" ;;
      delete) image_delete "${2:-}" "${3:-}" "${4:-}" ;;
      *) printf 'Usage: registry image {list|inspect|exists|digest|size|pull|push|copy|sign|verify|delete}\n'; exit 2 ;;
    esac
    ;;
  backup) backup_command "$@" ;;
  user|users) user_command "$@" ;;
  storage) storage_command "$@" ;;
  tls) tls_command "$@" ;;
  monitoring) monitoring_command "$@" ;;
  metrics) metrics_command "$@" ;;
  firewall) firewall_command "$@" ;;
  migrate) migration_command "$@" ;;
  gc|garbage-collect) load_env; gc_command "$@" ;;
  retention) load_env; retention_command "$@" ;;
  *) usage; exit 2 ;;
esac
