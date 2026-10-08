#!/usr/bin/env bash
#
# Manage a macOS LaunchAgent that starts the web-tool container at login and
# restarts it if it crashes -- the closest equivalent to Docker's
# `--restart always` on Apple's `container` runtime, which has no restart
# policy of its own.
#
# The agent keeps `run-web-tool-container.sh --foreground` alive via launchd's
# KeepAlive. It is a *user* agent: it starts when you log in, not at boot
# before login, and it cannot restart a container after a crash that happens
# while you are logged out.
#
# Usage:
#   web-tool-autostart.sh install
#   web-tool-autostart.sh uninstall
#   web-tool-autostart.sh status
#
# Environment overrides (baked into the agent at install time):
#   WEB_TOOL_PORT      host port to publish (default: 8532)
#   WEB_TOOL_DATA_DIR  host directory persisted as the container's /data
#                      (default: $HOME/docker-data/web-tool)
#   WEB_TOOL_IMAGE     image reference (default: docker.io/dockmann/web-tool)
#
# After installing, view logs with:
#   tail -f ~/Library/Logs/web-tool.log

set -euo pipefail

LABEL="com.dockmann.web-tool"
AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENT_DIR/$LABEL.plist"
LOG_FILE="$HOME/Library/Logs/web-tool.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="$SCRIPT_DIR/run-web-tool-container.sh"
DOMAIN="gui/$(id -u)"

PORT="${WEB_TOOL_PORT:-8532}"
DATA_DIR="${WEB_TOOL_DATA_DIR:-$HOME/docker-data/web-tool}"
IMAGE="${WEB_TOOL_IMAGE:-docker.io/dockmann/web-tool}"

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") {install|uninstall|status}

  install    write and load the launchd agent
  uninstall  unload and remove the launchd agent
  status     show the agent and container state
EOF
}

require_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "error: this script manages a launchd agent and is macOS-only" >&2
    exit 1
  fi
}

# Escape a value for use as plist XML text, so paths containing & or < do not
# produce a plist that launchctl refuses to load.
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

install_agent() {
  require_macos

  if [ ! -x "$RUN_SCRIPT" ]; then
    echo "error: $RUN_SCRIPT not found or not executable" >&2
    exit 1
  fi

  if ! command -v container >/dev/null 2>&1; then
    echo "error: Apple's 'container' CLI not found on PATH; install it first" >&2
    exit 1
  fi

  # launchd runs jobs with a minimal PATH that does not include Homebrew.
  # Bake in the directory of the container binary so the run script can find it.
  CONTAINER_DIR="$(dirname "$(command -v container)")"
  AGENT_PATH="$CONTAINER_DIR:/usr/bin:/bin:/usr/sbin:/sbin"

  mkdir -p "$AGENT_DIR" "$(dirname "$LOG_FILE")"

  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml_escape "$RUN_SCRIPT")</string>
    <string>--foreground</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$(xml_escape "$AGENT_PATH")</string>
    <key>WEB_TOOL_PORT</key>
    <string>$(xml_escape "$PORT")</string>
    <key>WEB_TOOL_DATA_DIR</key>
    <string>$(xml_escape "$DATA_DIR")</string>
    <key>WEB_TOOL_IMAGE</key>
    <string>$(xml_escape "$IMAGE")</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$LOG_FILE")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$LOG_FILE")</string>
</dict>
</plist>
PLIST_EOF

  # Reload cleanly: bootout an existing registration, then bootstrap the new one.
  # bootout returns before launchd has finished tearing the job down, and a
  # bootstrap issued in that window fails with "Input/output error", so wait
  # for the old registration to disappear first.
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 1
  done
  launchctl bootstrap "$DOMAIN" "$PLIST"

  echo "installed $PLIST"
  echo "web-tool will start at login and restart if it crashes while you are logged in."
  echo "logs: $LOG_FILE"
}

uninstall_agent() {
  require_macos

  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST"

  echo "removed $PLIST"
  echo "any running container was left in place; stop it with: container stop web-tool"
}

status_agent() {
  require_macos

  if [ -f "$PLIST" ]; then
    echo "plist: $PLIST"
  else
    echo "plist: not installed"
  fi

  echo
  echo "agent:"
  launchctl print "$DOMAIN/$LABEL" 2>/dev/null | sed -n '1,12p' || echo "  not loaded"

  echo
  echo "containers:"
  container list 2>/dev/null || echo "  container CLI not available"
}

case "${1:-}" in
  install) install_agent ;;
  uninstall) uninstall_agent ;;
  status) status_agent ;;
  *)
    usage
    exit 1
    ;;
esac
