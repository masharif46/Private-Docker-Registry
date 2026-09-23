#!/usr/bin/env bash
set -Eeuo pipefail

# Copy repositories and tags between the lightweight Registry API and Harbor.
# This script never deletes source images and never runs garbage collection.

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="${ENV_FILE:-.env}"
HARBOR_CREDENTIALS_FILE="${HARBOR_CREDENTIALS_FILE:-harbor/harbor-credentials.txt}"
ACTION="${1:-}"
SOURCE_KIND=""
DESTINATION_KIND=""
CONFIRM=0
DRY_RUN=0

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

usage() {
  cat <<'USAGE'
Usage:
  scripts/migrate-registries.sh backup [BACKUP_FILE]
  scripts/migrate-registries.sh restore-test BACKUP_FILE
  scripts/migrate-registries.sh doctor --source api|harbor --destination api|harbor
  scripts/migrate-registries.sh plan --source api|harbor --destination api|harbor
  scripts/migrate-registries.sh run --source api|harbor --destination api|harbor --confirm

Options:
  --source KIND       Source registry: api or harbor
  --destination KIND  Destination registry: api or harbor
  --confirm           Required by run; copying never deletes source data
  --dry-run           Plan without copying (same as plan)
  --env-file FILE     API registry environment file

The API registry backup and restore-test commands are safe with a running
registry. restore-test restores into a separate temporary Docker volume and
does not overwrite the live registry volume.
USAGE
}

load_api() {
  [[ -f "$ENV_FILE" ]] || die "$ENV_FILE does not exist"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  : "${REGISTRY_HOST:?REGISTRY_HOST is missing from $ENV_FILE}"
  : "${REGISTRY_USERNAME:?REGISTRY_USERNAME is missing from $ENV_FILE}"
  : "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is missing from $ENV_FILE}"
}

load_harbor() {
  [[ -f "$HARBOR_CREDENTIALS_FILE" ]] || die "Harbor credentials file not found: $HARBOR_CREDENTIALS_FILE"
  HARBOR_URL="$(awk -F': ' '$1=="Harbor URL" {print $2; exit}' "$HARBOR_CREDENTIALS_FILE")"
  HARBOR_USERNAME="$(awk -F': ' '$1=="Username" {print $2; exit}' "$HARBOR_CREDENTIALS_FILE")"
  HARBOR_PASSWORD="$(awk -F': ' '$1=="Password" {print $2; exit}' "$HARBOR_CREDENTIALS_FILE")"
  [[ "$HARBOR_URL" == https://* ]] || die 'Harbor credentials must contain an HTTPS Harbor URL.'
  [[ -n "$HARBOR_USERNAME" && -n "$HARBOR_PASSWORD" ]] || die 'Harbor credentials file is incomplete.'
  HARBOR_HOSTPORT="${HARBOR_URL#https://}"
  HARBOR_HOSTPORT="${HARBOR_HOSTPORT%%/*}"
}

registry_values() {
  local kind="$1"
  if [[ "$kind" == api ]]; then
    load_api
    REGISTRY_URL="https://${REGISTRY_HOST}"
    REGISTRY_HOSTPORT="$REGISTRY_HOST"
    REGISTRY_USER="$REGISTRY_USERNAME"
    REGISTRY_PASS="$REGISTRY_PASSWORD"
  elif [[ "$kind" == harbor ]]; then
    load_harbor
    REGISTRY_URL="$HARBOR_URL"
    REGISTRY_HOSTPORT="$HARBOR_HOSTPORT"
    REGISTRY_USER="$HARBOR_USERNAME"
    REGISTRY_PASS="$HARBOR_PASSWORD"
  else
    die "Registry kind must be api or harbor: $kind"
  fi
}

registry_request() {
  local kind="$1" path="$2"
  registry_values "$kind"
  curl --fail --silent --show-error --insecure \
    --user "$REGISTRY_USER:$REGISTRY_PASS" "$REGISTRY_URL$path"
}

catalog() {
  local kind="$1"
  # Harbor rejects catalog requests above its supported page size.
  registry_request "$kind" '/v2/_catalog?n=1000' | jq -r '.repositories[]?'
}

tags_for() {
  local kind="$1" repo="$2"
  registry_request "$kind" "/v2/$repo/tags/list" | jq -r '.tags[]?'
}

ensure_harbor_project() {
  local project="$1" body status
  load_harbor
  body="$(jq -cn --arg name "$project" '{project_name:$name,metadata:{public:"false"}}')"
  status="$(curl --silent --show-error --insecure --user "$HARBOR_USERNAME:$HARBOR_PASSWORD" \
    -H 'Content-Type: application/json' -o /dev/null -w '%{http_code}' \
    -X POST "$HARBOR_URL/api/v2.0/projects" --data "$body")"
  if [[ "$status" != 201 && "$status" != 409 ]]; then
    die "Could not create/check Harbor project $project (HTTP $status)"
  fi
}

backup_api() {
  need_command docker
  local requested="${1:-}" 
  if [[ -n "$requested" ]]; then
    "$ROOT_DIR/scripts/backup-registry.sh" "$requested"
  else
    "$ROOT_DIR/scripts/backup-registry.sh"
  fi
}

restore_test() {
  local backup="$1" test_volume
  [[ -f "$backup" ]] || die "Backup not found: $backup"
  [[ -f "$backup.sha256" ]] || die "Backup checksum not found: $backup.sha256"
  need_command docker
  need_command sha256sum
  (cd "$(dirname -- "$backup")" && sha256sum --check "$(basename -- "$backup").sha256")
  test_volume="registry-restore-test-$(date -u +%Y%m%dT%H%M%SZ)"
  docker volume create "$test_volume" >/dev/null
  REGISTRY_VOLUME="$test_volume" REGISTRY_CONTAINER_NAME="registry-restore-test-container" \
    "$ROOT_DIR/scripts/restore-registry.sh" "$backup" --confirm
  docker run --rm -v "$test_volume:/data:ro" alpine:3.22 \
    test -d /data/docker/registry
  printf 'Restore test passed in temporary volume: %s\n' "$test_volume"
  printf 'The temporary volume was preserved for inspection; the live registry volume was not touched.\n'
}

parse_options() {
  shift
  while (($#)); do
    case "$1" in
      --source) SOURCE_KIND="${2:-}"; shift 2 ;;
      --destination) DESTINATION_KIND="${2:-}"; shift 2 ;;
      --env-file) ENV_FILE="${2:-}"; shift 2 ;;
      --confirm) CONFIRM=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -n "$SOURCE_KIND" && -n "$DESTINATION_KIND" ]] || die 'Both --source and --destination are required.'
  [[ "$SOURCE_KIND" != "$DESTINATION_KIND" ]] || die 'Source and destination must be different registries.'
}

preflight() {
  need_command curl
  need_command jq
  need_command skopeo
  registry_request "$SOURCE_KIND" '/v2/' >/dev/null
  registry_request "$DESTINATION_KIND" '/v2/' >/dev/null
  local source_count destination_count
  source_count="$(catalog "$SOURCE_KIND" | wc -l)"
  destination_count="$(catalog "$DESTINATION_KIND" | wc -l)"
  printf 'PASS source=%s repositories=%s\n' "$SOURCE_KIND" "$source_count"
  printf 'PASS destination=%s repositories=%s\n' "$DESTINATION_KIND" "$destination_count"
  if [[ "$DESTINATION_KIND" == harbor ]]; then
    load_harbor
    curl --fail --silent --show-error --insecure --user "$HARBOR_USERNAME:$HARBOR_PASSWORD" \
      "$HARBOR_URL/api/v2.0/systeminfo" >/dev/null
    printf 'PASS Harbor API authentication\n'
  fi
}

copy_all() {
  local repo tag project source_ref destination_ref total=0
  local source_hostport source_user source_pass destination_hostport destination_user destination_pass
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    if [[ "$DESTINATION_KIND" == harbor ]]; then
      project="${repo%%/*}"
      ensure_harbor_project "$project"
    fi
    while IFS= read -r tag; do
      [[ -n "$tag" ]] || continue
      total=$((total + 1))
      registry_values "$SOURCE_KIND"
      source_hostport="$REGISTRY_HOSTPORT"
      source_user="$REGISTRY_USER"
      source_pass="$REGISTRY_PASS"
      source_ref="docker://$source_hostport/$repo:$tag"
      registry_values "$DESTINATION_KIND"
      destination_hostport="$REGISTRY_HOSTPORT"
      destination_user="$REGISTRY_USER"
      destination_pass="$REGISTRY_PASS"
      destination_ref="docker://$destination_hostport/$repo:$tag"
      printf '[%s] %s -> %s\n' "$total" "${source_ref#docker://}" "${destination_ref#docker://}"
      if (( DRY_RUN == 0 )); then
        # --all preserves OCI/Docker multi-architecture indexes instead of
        # silently selecting only the current host architecture.
        skopeo copy --all --src-tls-verify=false --dest-tls-verify=false \
          --src-creds "$source_user:$source_pass" \
          --dest-creds "$destination_user:$destination_pass" \
          "$source_ref" "$destination_ref"
        source_digest="$(skopeo inspect --tls-verify=false --creds "$source_user:$source_pass" --format '{{.Digest}}' "$source_ref")"
        destination_digest="$(skopeo inspect --tls-verify=false --creds "$destination_user:$destination_pass" --format '{{.Digest}}' "$destination_ref")"
        [[ "$source_digest" == "$destination_digest" ]] || die "Digest mismatch for $repo:$tag"
        printf '  VERIFIED digest=%s\n' "$source_digest"
      fi
    done < <(tags_for "$SOURCE_KIND" "$repo")
  done < <(catalog "$SOURCE_KIND")
  printf 'Total tags processed/planned: %s\n' "$total"
}

case "$ACTION" in
  backup)
    need_command docker
    backup_api "${2:-}"
    ;;
  restore-test)
    [[ -n "${2:-}" ]] || die 'Usage: restore-test BACKUP_FILE'
    restore_test "$2"
    ;;
  doctor)
    parse_options "$@"
    preflight
    ;;
  plan)
    parse_options "$@"
    preflight
    DRY_RUN=1
    copy_all
    ;;
  run)
    parse_options "$@"
    (( CONFIRM == 1 )) || die 'Migration requires --confirm. No changes were made.'
    preflight
    copy_all
    ;;
  --help|-h|'') usage; [[ -n "$ACTION" ]] || exit 0; exit 2 ;;
  *) die "Unknown action: $ACTION" ;;
esac
