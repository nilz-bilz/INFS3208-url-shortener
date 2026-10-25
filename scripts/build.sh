#!/usr/bin/env bash
# Build all four images as localhost/<name>:<tag>. Usage: ./scripts/build.sh v1
set -euo pipefail

# Tag to build; required so every image is versioned explicitly
TAG="${1:?usage: build.sh <tag>}"
# Repo root, so the script works from any directory
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Container engine: podman if installed (developer machine), otherwise docker (override with CONTAINER_ENGINE=...)
ENGINE="${CONTAINER_ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"

for NAME in shortener redirect analytics frontend; do
  # build: -t names the image, --build-arg bakes APP_VERSION in (shown in X-App-Version and the UI footer),
  # the last argument is the build context (the service folder)
  "$ENGINE" build --build-arg APP_VERSION="$TAG" -t "localhost/$NAME:$TAG" "$ROOT/$NAME"
done

# List the images just built (--filter reference= matches by name:tag)
"$ENGINE" images --filter "reference=localhost/*:$TAG"
