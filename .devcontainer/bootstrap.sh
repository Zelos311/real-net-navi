#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[Lamp Hub] Installing workstation packages..."
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  xvfb openbox x11vnc novnc websockify \
  xdotool wmctrl scrot imagemagick dbus-x11 \
  krita curl jq openssl ca-certificates

mkdir -p "$HOME/.lamp-hub/logs" "$HOME/.lamp-hub/art" "$HOME/.lamp-hub/projects"

# Keep the workspace tidy and make the control scripts executable.
chmod +x .devcontainer/start-lamp-hub.sh || true

echo "[Lamp Hub] Bootstrap complete."
