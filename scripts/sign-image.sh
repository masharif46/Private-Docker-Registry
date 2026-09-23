#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:-}"
[[ -n "$IMAGE" ]] || { printf 'Usage: %s REGISTRY_HOST/team/image:tag\n' "$0" >&2; exit 2; }
command -v cosign >/dev/null 2>&1 || { printf 'Error: cosign is required\n' >&2; exit 1; }

if [[ -n "${COSIGN_KEY:-}" ]]; then
  cosign sign --key "$COSIGN_KEY" "$IMAGE"
else
  printf '%s\n' 'No COSIGN_KEY set; using Cosign keyless signing. An OIDC identity may be required.'
  cosign sign "$IMAGE"
fi

