#!/usr/bin/env bash
#
# Run the published web-tool image with Apple's `container` runtime (macOS).
#
# Stops and removes any existing "web-tool" container, pulls the latest image,
# and starts a new container. Apple's runtime has no `--restart` policy, so for
# automatic restart use web-tool-autostart.sh, which runs this script in
# --foreground mode under a launchd agent.
#
# Usage:
#   run-web-tool-container.sh              # start detached, print the URL
#   run-web-tool-container.sh --foreground # run attached (used by launchd)
#
# Environment overrides:
#   WEB_TOOL_PORT      host port to publish (default: 8532)
#   WEB_TOOL_DATA_DIR  host directory persisted as the container's /data
#                      (default: $HOME/docker-data/web-tool)
#   WEB_TOOL_IMAGE     image reference (default: docker.io/dockmann/web-tool)

set -euo pipefail

PORT="${WEB_TOOL_PORT:-8532}"
DATA_DIR="${WEB_TOOL_DATA_DIR:-$HOME/docker-data/web-tool}"
IMAGE="${WEB_TOOL_IMAGE:-docker.io/dockmann/web-tool}"
CONTAINER_NAME="web-tool"

FOREGROUND=false
case "${1:-}" in
  --foreground) FOREGROUND=true ;;
  "") ;;
  *)
    echo "error: unknown argument: $1" >&2
    echo "usage: $(basename "$0") [--foreground]" >&2
    exit 1
    ;;
esac

if ! command -v container >/dev/null 2>&1; then
  echo "error: Apple's 'container' CLI not found on PATH" >&2
  echo "install it with: brew install container" >&2
  echo "or download the signed installer from https://github.com/apple/container/releases" >&2
  exit 1
fi

# Bring up the container services. This is idempotent; --enable-kernel-install
# avoids the interactive kernel prompt on the first run, and --timeout gives a
# cold apiserver time to become responsive.
container system start --enable-kernel-install --timeout 60

# Create the data directory as the current user. If the runtime creates the
# bind mount target itself it owns it as root, and the container's appuser
# (uid 1000) can then no longer write the favicon cache to it.
mkdir -p "$DATA_DIR"

# Pull before removing the old container so a failed pull (offline, registry
# error) leaves the existing container running. Under launchd (--foreground) a
# failed pull is tolerated when the image is already cached, so logging in
# without a network still starts web-tool.
if ! container image pull "$IMAGE"; then
  if $FOREGROUND && container image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "warning: image pull failed; starting the cached $IMAGE" >&2
  else
    exit 1
  fi
fi

# Remove any existing container, ignoring errors when it is absent.
container delete --force "$CONTAINER_NAME" >/dev/null 2>&1 || true

# CONTAINER_RUNTIME tells web-tool it is containerized. Apple's runtime leaves
# none of the Docker markers the app otherwise detects (/.dockerenv, cgroup
# names), and without it the app listens on its dev port instead of 8532 and
# ignores /data.
# The explicit 127.0.0.1 keeps the port off the network; with no host IP,
# `container run -p` binds all interfaces.
RUN_ARGS=(
  -p "127.0.0.1:${PORT}:8532"
  -v "${DATA_DIR}:/data"
  -e "CONTAINER_RUNTIME=apple-container"
  --name "$CONTAINER_NAME"
  "$IMAGE"
)

if $FOREGROUND; then
  # Attached mode for launchd: exec so launchd supervises this process and can
  # restart it when it exits unexpectedly.
  exec container run "${RUN_ARGS[@]}"
else
  container run -d "${RUN_ARGS[@]}"
  echo "web-tool running at http://localhost:${PORT}"
fi
