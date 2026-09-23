#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REPOSITORY="${1:-}"
KEEP_DAYS="${2:-}"
ACTION="${3:-}"
CONFIRM="${4:-}"
[[ -n "$REPOSITORY" && -n "$KEEP_DAYS" ]] || { printf 'Usage: %s REPOSITORY KEEP_DAYS [--delete --confirm]\n' "$0" >&2; exit 2; }
[[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || { printf 'KEEP_DAYS must be a non-negative integer\n' >&2; exit 2; }
[[ -f .env ]] || { printf 'Error: .env is required\n' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { printf 'Error: curl is required\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'Error: jq is required\n' >&2; exit 1; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

set -a
# shellcheck disable=SC1091
source .env
set +a
: "${REGISTRY_HOST:?REGISTRY_HOST is missing from .env}"
: "${REGISTRY_USERNAME:?REGISTRY_USERNAME is missing from .env}"
: "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is missing from .env}"

API="https://${REGISTRY_HOST}/v2/${REPOSITORY}"
ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
CA_ARGS=()
caddy_running="$(docker inspect private-registry-caddy --format '{{.State.Running}}' 2>/dev/null || true)"
if [[ -n "${REGISTRY_CA_FILE:-}" && -f "$REGISTRY_CA_FILE" ]]; then
  CA_ARGS=(--cacert "$REGISTRY_CA_FILE")
elif [[ "$caddy_running" != true && -f registry/certs/registry.crt ]]; then
  CA_ARGS=(--cacert registry/certs/registry.crt)
fi
AUTH_ARGS=(--user "$REGISTRY_USERNAME:$REGISTRY_PASSWORD")
cutoff="$(date -u -d "${KEEP_DAYS} days ago" +%s)"
delete_mode=false
if [[ "$ACTION" == "--delete" ]]; then
  [[ "$CONFIRM" == "--confirm" ]] || { printf 'Deletion requires both --delete and --confirm.\n' >&2; exit 2; }
  delete_mode=true
fi

request() {
  curl --fail --silent --show-error "${CA_ARGS[@]}" "${AUTH_ARGS[@]}" "$@"
}

manifest_digest() {
  request --dump-header - --output /dev/null -H "Accept: $ACCEPT" "$API/manifests/$1" |
    awk -F': ' 'tolower($1)=="docker-content-digest" {gsub("\r", "", $2); print $2; exit}'
}

created_epoch_for_manifest() {
  local reference="$1" manifest config_digest config created newest=0 epoch child
  manifest="$(request -H "Accept: $ACCEPT" "$API/manifests/$reference")" || return 1
  config_digest="$(jq -r '.config.digest // empty' <<< "$manifest")"
  if [[ -n "$config_digest" ]]; then
    config="$(request "$API/blobs/$config_digest")" || return 1
    created="$(jq -r '.created // empty' <<< "$config")"
    if [[ -n "$created" ]]; then
      date -u -d "$created" +%s 2>/dev/null || true
    fi
    return 0
  fi

  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    epoch="$(created_epoch_for_manifest "$child")" || return 1
    [[ "$epoch" =~ ^[0-9]+$ ]] || continue
    (( epoch > newest )) && newest="$epoch"
  done < <(jq -r '.manifests[]?.digest' <<< "$manifest")
  (( newest > 0 )) && printf '%s\n' "$newest"
  return 0
}

tags_json="$(request "$API/tags/list")" || die "unable to list tags for $REPOSITORY"
jq -e '.tags == null or (.tags | type == "array")' >/dev/null <<< "$tags_json" || die 'registry returned an invalid tags response'
mapfile -t tags < <(jq -r '.tags[]?' <<< "$tags_json")
declare -A digest_count=()
declare -A tag_digest=()
for tag in "${tags[@]}"; do
  digest="$(manifest_digest "$tag")" || die "unable to read manifest digest for $tag"
  [[ -n "$digest" ]] || { printf 'Skipping %s (manifest digest missing)\n' "$tag"; continue; }
  tag_digest["$tag"]="$digest"
  digest_count["$digest"]=$(( ${digest_count["$digest"]:-0} + 1 ))
done

for tag in "${tags[@]}"; do
  digest="${tag_digest[$tag]:-}"
  [[ -n "$digest" ]] || continue
  created_epoch="$(created_epoch_for_manifest "$tag")" || die "unable to inspect image metadata for $tag"
  [[ "$created_epoch" =~ ^[0-9]+$ ]] || { printf 'Skipping %s (no readable image-created timestamp)\n' "$tag"; continue; }
  if (( created_epoch < cutoff )); then
    created="$(date -u -d "@$created_epoch" +%Y-%m-%dT%H:%M:%SZ)"
    shared_count="${digest_count[$digest]}"
    printf '%s %s (image created %s; digest references: %s)\n' "$tag" "$digest" "$created" "$shared_count"
    if $delete_mode; then
      if (( shared_count > 1 )); then
        printf 'Skipping deletion of %s because multiple tags share its digest.\n' "$tag" >&2
        continue
      fi
      request -X DELETE "$API/manifests/$digest" >/dev/null
      printf 'Deleted %s\n' "$tag"
    fi
  fi
done

if ! $delete_mode; then
  printf '%s\n' 'Dry run only. Dates are image build timestamps, not registry push timestamps.'
  printf '%s\n' 'To delete unshared matches: --delete --confirm'
fi
