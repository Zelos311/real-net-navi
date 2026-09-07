#!/usr/bin/env bash
set -euo pipefail

HOOK="${LAMP_HUB_HOOK:-https://hook.us2.make.com/vse7mcseyuczci5j3nw87ucyjyx0wneo}"
ROOT="${GITHUB_WORKSPACE:-$PWD}"
TMP=/tmp/genie-gba-actions
mkdir -p "$TMP"
export DISPLAY=:99

sudo apt-get update
sudo apt-get install -y --no-install-recommends xvfb openbox x11vnc novnc websockify xdotool wmctrl scrot imagemagick dbus-x11 curl jq ca-certificates

if ! command -v cloudflared >/dev/null 2>&1; then
  curl -fsSL --retry 3 https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o "$TMP/cloudflared"
  chmod +x "$TMP/cloudflared"
  sudo mv "$TMP/cloudflared" /usr/local/bin/cloudflared
fi

nohup Xvfb :99 -screen 0 1280x720x24 -ac +extension GLX +render -noreset >"$TMP/xvfb.log" 2>&1 &
sleep 2
nohup env DISPLAY=:99 dbus-launch --exit-with-session openbox-session >"$TMP/openbox.log" 2>&1 &
sleep 1

nohup x11vnc -display :99 -forever -shared -viewonly -nopw -localhost -rfbport 5900 >"$TMP/x11vnc.log" 2>&1 &
nohup websockify --web=/usr/share/novnc/ 6080 localhost:5900 >"$TMP/novnc.log" 2>&1 &

# Small read-only frame server for Genie's vision loop.
touch "$TMP/frame.jpg"
(
  while true; do
    scrot -z -q 35 -o "$TMP/frame-full.jpg" >/dev/null 2>&1 || true
    if [ -s "$TMP/frame-full.jpg" ]; then
      convert "$TMP/frame-full.jpg" -resize '640x360>' -quality 35 "$TMP/frame.jpg" >/dev/null 2>&1 || true
    fi
    sleep 1
  done
) &
nohup python3 -m http.server 8787 --bind 127.0.0.1 --directory "$TMP" >"$TMP/frame-http.log" 2>&1 &

nohup cloudflared tunnel --no-autoupdate --url http://127.0.0.1:6080 >"$TMP/view-tunnel.log" 2>&1 &
nohup cloudflared tunnel --no-autoupdate --url http://127.0.0.1:8787 >"$TMP/frame-tunnel.log" 2>&1 &

view=""
frame=""
for i in $(seq 1 60); do
  view="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' "$TMP/view-tunnel.log" | tail -1 || true)"
  frame="$(grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' "$TMP/frame-tunnel.log" | tail -1 || true)"
  [ -n "$view" ] && [ -n "$frame" ] && break
  sleep 1
done
[ -n "$view" ] && [ -n "$frame" ]

viewer="${view}/vnc_lite.html?autoconnect=true&resize=scale&path=websockify"
frame_url="${frame}/frame.jpg"

payload="$(jq -n --arg client_id "github-actions-gba-${GITHUB_RUN_ID:-manual}" --arg viewer "$viewer" --arg frame "$frame_url" '{client_id:$client_id,hostname:"github-actions",status:"gba_session_ready",viewer_url:$viewer,frame_url:$frame}')"
curl -fsS -H 'Content-Type: application/json' --data-binary "$payload" "$HOOK" >/dev/null || true

exec bash "$ROOT/.devcontainer/make-poller.sh" "$HOOK"
