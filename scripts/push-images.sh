#!/usr/bin/env bash
set -Eeuo pipefail

CALLER_DIR="$PWD"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="${ENV_FILE:-.env}"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
  printf 'Usage:\n'
  printf '  %s                         # interactive prompt\n' "$0"
  printf '  %s SOURCE_IMAGE [DESTINATION_IMAGE]\n' "$0"
  printf '  %s --file IMAGE_FILE\n' "$0"
}

command -v docker >/dev/null 2>&1 || die 'Required command not found: docker'
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE does not exist. Run: cp .env.example .env"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
: "${REGISTRY_HOST:?REGISTRY_HOST is missing from $ENV_FILE}"

push_image() {
  local source_image="$1" destination_image="${2:-$1}" target_image
  [[ -n "$source_image" ]] || die 'Source image cannot be empty.'
  [[ -n "$destination_image" ]] || destination_image="$source_image"

  if [[ "$destination_image" == "$REGISTRY_HOST/"* ]]; then
    target_image="$destination_image"
  else
    target_image="${REGISTRY_HOST}/${destination_image}"
  fi

  printf '\n==> Pulling %s\n' "$source_image"
  docker pull "$source_image"
  printf '==> Tagging %s\n' "$target_image"
  docker tag "$source_image" "$target_image"
  printf '==> Pushing %s\n' "$target_image"
  docker push "$target_image"
  printf 'Successfully pushed: %s\n' "$target_image"
}

push_file() {
  local image_file="$1" line source_image destination_image count=0
  [[ -f "$image_file" ]] || die "Image file does not exist: $image_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    read -r source_image destination_image _ <<< "$line" || true
    [[ -n "${source_image:-}" ]] || continue
    push_image "$source_image" "${destination_image:-$source_image}"
    count=$((count + 1))
  done < "$image_file"

  printf '\nPushed %d image(s) to %s\n' "$count" "$REGISTRY_HOST"
}

case "$#" in
  0)
    [[ -t 0 ]] || { usage >&2; die 'No image supplied and input is not an interactive terminal.'; }
    printf 'Private registry: %s\n' "$REGISTRY_HOST"
    read -r -p 'Source image link (example: nginx:1.27): ' source_image || die 'Unable to read source image.'
    [[ -n "$source_image" ]] || die 'Source image cannot be empty.'
    read -r -p 'Destination repository:tag (press Enter to keep source name): ' destination_image || true
    push_image "$source_image" "${destination_image:-$source_image}"
    ;;
  1)
    if [[ "$1" == "--help" || "$1" == "-h" ]]; then
      usage
    elif [[ -f "$1" ]]; then
      push_file "$1"
    elif [[ -f "$CALLER_DIR/$1" ]]; then
      push_file "$CALLER_DIR/$1"
    else
      push_image "$1"
    fi
    ;;
  2)
    if [[ "$1" == "--file" ]]; then
      image_file="$2"
      [[ "$image_file" == /* ]] || image_file="$CALLER_DIR/$image_file"
      push_file "$image_file"
    else
      push_image "$1" "$2"
    fi
    ;;
  *) usage >&2; exit 2 ;;
esac
