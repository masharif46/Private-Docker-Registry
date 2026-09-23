#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VOLUME_NAME="${REGISTRY_VOLUME:-private-docker-registry-data}"
REGISTRY_CONTAINER_NAME="${REGISTRY_CONTAINER_NAME:-private-docker-registry}"
delete_flag=""
[[ "${1:-}" == "--delete" ]] && delete_flag="--delete-untagged"
if docker ps --format '{{.Names}}' | grep -qx "$REGISTRY_CONTAINER_NAME"; then
  printf '%s\n' 'Stop the registry first; garbage collection requires read-only mode or a stopped registry.' >&2
  exit 1
fi
if [[ -z "$delete_flag" ]]; then
  printf '%s\n' 'Dry run: no blobs will be deleted.'
  printf '%s\n' 'To delete untagged blobs, stop the registry and run: scripts/garbage-collect.sh --delete'
else
  [[ "${2:-}" == "--confirm" ]] || { printf '%s\n' 'Deletion requires: scripts/garbage-collect.sh --delete --confirm' >&2; exit 2; }
fi

docker run --rm \
  -v "$VOLUME_NAME:/var/lib/registry" \
  registry:3.1.1 garbage-collect $delete_flag /etc/distribution/config.yml
