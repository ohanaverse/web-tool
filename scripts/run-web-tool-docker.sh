#!/usr/bin/env bash
#
# Run the published web-tool image with Docker.
#
# Stops and removes any existing "web-tool" container, pulls the latest image,
# and starts a new detached container that restarts automatically.
#
# For the equivalent script using Apple's `container` runtime on macOS, see
# run-web-tool-container.sh and web-tool-autostart.sh.
#
# Environment overrides:
#   WEB_TOOL_PORT      host port to publish (default: 8532)
#   WEB_TOOL_DATA_DIR  host directory persisted as the container's /data
#                      (default: $HOME/docker-data/web-tool)
#   WEB_TOOL_IMAGE     image reference (default: dockmann/web-tool)

set -euo pipefail

PORT="${WEB_TOOL_PORT:-8532}"
DATA_DIR="${WEB_TOOL_DATA_DIR:-$HOME/docker-data/web-tool}"
IMAGE="${WEB_TOOL_IMAGE:-dockmann/web-tool}"
CONTAINER_NAME="web-tool"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker not found on PATH" >&2
  exit 1
fi

# Create the data directory as the current user. If Docker creates the bind
# mount target itself it owns it as root, and the container's appuser (uid
# 1000) can then no longer write the favicon cache to it.
mkdir -p "$DATA_DIR"

# Pull before removing the old container so a failed pull (offline, registry
# error) leaves the existing container running.
docker pull "$IMAGE"

# Stop and remove any existing container, ignoring errors when it is absent.
docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -d --restart always \
  -p "${PORT}:8532" \
  -v "${DATA_DIR}:/data" \
  --name "$CONTAINER_NAME" \
  "$IMAGE"

echo "web-tool running at http://localhost:${PORT}"
