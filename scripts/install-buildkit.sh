#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDER_NAME="${BUILDKIT_BUILDER:-private-buildkit}"
ACTION=--check
DRIVER=docker-container
ENDPOINT=""
KUBE_CONTEXT=""
KUBE_NAMESPACE=buildkit
REMOTE_REQUESTED=0

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

usage() {
  cat <<'USAGE'
Usage: scripts/install-buildkit.sh [--check|--up|--use] [OPTIONS]

Checks Docker BuildKit/buildx or creates a dedicated docker-container builder.

  --check         Verify the existing Docker/buildx/BuildKit installation.
  --up            Create the builder if missing and bootstrap it.
  --use           Select an existing builder without creating it.
  --builder NAME  Use a custom builder name (default: private-buildkit).
  --docker-context NAME
                  Create a builder on a Docker context or endpoint.
  --ssh TARGET    Create a remote builder through SSH, for example
                  ssh://builder@buildkit.example.com.
  --kubernetes-context NAME
                  Create a builder using a Kubernetes kubeconfig context.
  --kubernetes-namespace NAME
                  Kubernetes namespace (default: buildkit).

This script does not modify registry images, registry volumes, or Docker Hub
cache data. BuildKit build-cache artifacts are separate from the Docker Hub
pull-through cache and from the final private image registry.
The default builder uses the current local Docker context. Remote builders are
created only when an explicit remote option is provided.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|--up|--use) ACTION="$1"; shift ;;
    --docker-context|--context)
      [[ -n "${2:-}" ]] || die "$1 requires a context or endpoint."
      DRIVER=docker-container
      ENDPOINT="$2"
      REMOTE_REQUESTED=1
      shift 2
      ;;
    --ssh)
      [[ -n "${2:-}" ]] || die '--ssh requires an SSH target.'
      DRIVER=docker-container
      ENDPOINT="$2"
      [[ "$ENDPOINT" == ssh://* ]] || ENDPOINT="ssh://$ENDPOINT"
      REMOTE_REQUESTED=1
      shift 2
      ;;
    --kubernetes-context)
      [[ -n "${2:-}" ]] || die '--kubernetes-context requires a context name.'
      DRIVER=kubernetes
      KUBE_CONTEXT="$2"
      REMOTE_REQUESTED=1
      shift 2
      ;;
    --kubernetes-namespace)
      [[ -n "${2:-}" ]] || die '--kubernetes-namespace requires a namespace.'
      KUBE_NAMESPACE="$2"
      shift 2
      ;;
    --builder)
      [[ -n "${2:-}" ]] || die '--builder requires a name.'
      BUILDER_NAME="$2"
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

need_command docker
docker info >/dev/null 2>&1 || die 'Docker daemon is not available.'
docker buildx version >/dev/null 2>&1 || die 'Docker buildx/BuildKit is not available.'

builder_exists=0
if docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  builder_exists=1
fi

if (( builder_exists == 1 && REMOTE_REQUESTED == 1 )); then
  die "Builder already exists: $BUILDER_NAME. Use --builder with a new name for a remote builder."
fi

kubeconfig_temp=""
cleanup() {
  [[ -z "$kubeconfig_temp" ]] || rm -f -- "$kubeconfig_temp"
}
trap cleanup EXIT

if [[ "$DRIVER" == kubernetes && -n "$KUBE_CONTEXT" ]]; then
  need_command kubectl
  kubeconfig_temp="$(mktemp)"
  kubectl config view --raw --flatten --minify --context "$KUBE_CONTEXT" > "$kubeconfig_temp"
  export KUBECONFIG="$kubeconfig_temp"
fi

if [[ "$ACTION" == --up ]]; then
  if (( builder_exists == 0 )); then
    create_args=(
      docker buildx create
      --name "$BUILDER_NAME"
      --driver docker-container
      --use
    )
    if [[ "$DRIVER" == kubernetes ]]; then
      create_args=(
        docker buildx create
        --name "$BUILDER_NAME"
        --driver kubernetes
        --driver-opt "namespace=$KUBE_NAMESPACE"
        --use
      )
    elif [[ -n "$ENDPOINT" ]]; then
      create_args+=("$ENDPOINT")
    fi
    "${create_args[@]}"
  else
    docker buildx use "$BUILDER_NAME"
  fi
  docker buildx inspect "$BUILDER_NAME" --bootstrap
elif [[ "$ACTION" == --use ]]; then
  (( builder_exists == 1 )) || die "BuildKit builder does not exist: $BUILDER_NAME"
  docker buildx use "$BUILDER_NAME"
fi

printf 'Docker: '
docker version --format '{{.Server.Version}}'
printf 'Buildx: '
docker buildx version
printf 'Builder: %s (driver=%s' "$BUILDER_NAME" "$DRIVER"
[[ -z "$ENDPOINT" ]] || printf ', endpoint=%s' "$ENDPOINT"
[[ -z "$KUBE_CONTEXT" ]] || printf ', kubernetes-context=%s, namespace=%s' "$KUBE_CONTEXT" "$KUBE_NAMESPACE"
printf ')\n'
if docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  docker buildx inspect "$BUILDER_NAME" | sed -n '1,12p'
else
  printf 'Builder is not created; run: %s --up\n' "$ROOT_DIR/scripts/install-buildkit.sh"
fi
