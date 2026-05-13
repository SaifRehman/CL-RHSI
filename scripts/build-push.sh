#!/usr/bin/env bash
# Build and push todo + weather images to Quay.
# Requires: QUAY_USER and QUAY_TOKEN env vars.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${QUAY_USER:?set QUAY_USER}"
: "${QUAY_TOKEN:?set QUAY_TOKEN}"

echo ">>> podman login quay.io"
echo "$QUAY_TOKEN" | podman login quay.io -u "$QUAY_USER" --password-stdin

echo ">>> build + push todo"
podman build --platform=linux/amd64 -t quay.io/rh-ee-srehman/todo:latest -f "$HERE/apps/todo_backend/Containerfile" "$HERE/apps/todo_backend"
podman push quay.io/rh-ee-srehman/todo:latest

echo ">>> build + push weather"
podman build --platform=linux/amd64 -t quay.io/rh-ee-srehman/weather:latest -f "$HERE/apps/weather/Containerfile" "$HERE/apps/weather"
podman push quay.io/rh-ee-srehman/weather:latest

echo ">>> done."
