#!/usr/bin/env bash
set -euo pipefail

HUB="$HOME/.lamp-hub"
LOG="$HUB/logs"
TOKEN_FILE="$HUB/relay-token"
HANDSHAKE_FILE="$HUB/handshake.json"
DISPLAY_NUM="${DISPLAY:-:1}"
mkdir -p "$LOG"

if [ ! -s "$TOKEN_FILE" ]; then
  python3 - <<'PY' > "$TOKEN_FILE"
import secrets
print(secrets.token_urlsafe(48))
PY
  chmod 600 "$TOKEN_FILE"
fi
TOKEN="$(cat "$TOKEN_FILE")"

if ! pgrep -f "Xvfb ${DISPLAY_NUM}" >/dev/null 2>&1; then
  nohup Xvfb "$DISPLAY_NUM" -screen 0 1280x720x24 -ac +extension GLX +render -noreset     >"$LOG/xvfb.log" 2>&1 &
  sleep 2
fi

if ! pgrep -f "openbox-session" >/dev/null 2>&1; then
  nohup env DISPLAY="$DISPLAY_NUM" dbus-launch --exit-with-session openbox-session     >"$LOG/openbox.log" 2>&1 &
fi

if ! pgrep -f "x11vnc.*${DISPLAY_NUM}" >/dev/null 2>&1; then
  nohup x11vnc -display "$DISPLAY_NUM" -forever -shared -nopw -localhost     >"$LOG/x11vnc.log" 2>&1 &
fi
if ! pgrep -f "websockify.*6080" >/dev/null 2>&1; then
  nohup websockify --web=/usr/share/novnc 6080 localhost:5900     >"$LOG/novnc.log" 2>&1 &
fi

CIPHER="$(printf '%s' "$TOKEN" | openssl pkeyutl -encrypt   -pubin -inkey .devcontainer/make-public.pem   -pkeyopt rsa_padding_mode:oaep   -pkeyopt rsa_oaep_md:sha256 | base64 -w0)"

PORT_DOMAIN="${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
RELAY_URL="https://${CODESPACE_NAME}-8787.${PORT_DOMAIN}"
DESKTOP_URL="https://${CODESPACE_NAME}-6080.${PORT_DOMAIN}/vnc.html?autoconnect=true&resize=scale"

python3 - "$HANDSHAKE_FILE" "$CIPHER" "$RELAY_URL" "$DESKTOP_URL" <<'PY'
import json, sys, time, os
path, cipher, relay_url, desktop_url = sys.argv[1:5]
payload = {
    "protocol": "lamp-hub-rsa-oaep-sha256-v1",
    "codespace_name": os.environ.get("CODESPACE_NAME"),
    "relay_url": relay_url,
    "desktop_url": desktop_url,
    "relay_token_ciphertext": cipher,
    "updated_at": int(time.time()),
}
with open(path, "w") as f:
    json.dump(payload, f)
PY
chmod 600 "$HANDSHAKE_FILE"

if ! pgrep -f "lamp-relay.py" >/dev/null 2>&1; then
  nohup env     DISPLAY="$DISPLAY_NUM"     LAMP_HUB_TOKEN="$TOKEN"     LAMP_HUB_PORT=8787     LIBGL_ALWAYS_SOFTWARE=1     QT_XCB_GL_INTEGRATION=none     python3 .devcontainer/lamp-relay.py     >"$LOG/relay.log" 2>&1 &
fi

echo "[Lamp Hub] Online."
echo "[Lamp Hub] Relay listener ready on port 8787."
echo "[Lamp Hub] Desktop listener ready on port 6080."
