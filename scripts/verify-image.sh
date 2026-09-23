#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:-}"
[[ -n "$IMAGE" ]] || { printf 'Usage: %s REGISTRY_HOST/team/image:tag\n' "$0" >&2; exit 2; }
command -v cosign >/dev/null 2>&1 || { printf 'Error: cosign is required\n' >&2; exit 1; }

if [[ -n "${COSIGN_PUBLIC_KEY:-}" ]]; then
  cosign verify --key "$COSIGN_PUBLIC_KEY" "$IMAGE"
else
  cosign verify "$IMAGE"
fi

