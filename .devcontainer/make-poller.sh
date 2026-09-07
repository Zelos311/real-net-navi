#!/usr/bin/env bash
set -u

HOOK="${1:-${LAMP_HUB_HOOK:-}}"
if [ -z "$HOOK" ]; then
  echo "Usage: $0 <make-webhook-url>" >&2
  exit 2
fi

HUB="$HOME/.lamp-hub"
LOG="$HUB/logs"
mkdir -p "$LOG"

CLIENT_FILE="$HUB/client-id"
if [ ! -s "$CLIENT_FILE" ]; then
  python3 - <<'PY' > "$CLIENT_FILE"
import uuid
print(uuid.uuid4())
PY
fi
CLIENT_ID="$(cat "$CLIENT_FILE")"

LAST_ACTION_FILE="$HUB/last-action-id"
LAST_ACTION_ID="$(cat "$LAST_ACTION_FILE" 2>/dev/null || true)"

RESULT_ACTION_ID=""
RESULT_ACTION=""
RESULT_OK=""
RESULT_OUTPUT=""

echo "[Lamp Hub] Make control poller starting as $CLIENT_ID"

gba_focus() {
  env DISPLAY="${DISPLAY:-:1}" wmctrl -a "GBA Online" >/dev/null 2>&1 ||
  env DISPLAY="${DISPLAY:-:1}" wmctrl -a "pokemongreen" >/dev/null 2>&1 ||
  env DISPLAY="${DISPLAY:-:1}" wmctrl -a "Google Chrome" >/dev/null 2>&1 ||
  true
}

gba_key() {
  local key="$1"
  gba_focus
  sleep 0.15
  env DISPLAY="${DISPLAY:-:1}" xdotool key --clearmodifiers "$key"
}

gba_frame() {
  local shot="$HUB/gba-frame.jpg"
  env DISPLAY="${DISPLAY:-:1}" scrot -z -o "$shot"
  convert "$shot" -resize '320x180>' -quality 28 "$shot"
  printf 'data:image/jpeg;base64,'
  base64 -w0 "$shot"
}

run_action() {
  local name="$1"
  case "$name" in
    hub_status)
      {
        echo "codespace=${CODESPACE_NAME:-unknown}"
        echo "hostname=$(hostname)"
        echo "display=${DISPLAY:-:1}"
        echo "uptime=$(uptime -p 2>/dev/null || true)"
        echo "relay=$(pgrep -f 'lamp-relay.py' >/dev/null 2>&1 && echo online || echo offline)"
        echo "poller=online"
        echo "krita=$(pgrep -x krita >/dev/null 2>&1 && echo running || echo stopped)"
        echo "chrome=$(pgrep -f 'google-chrome.*gba-chrome' >/dev/null 2>&1 && echo running || echo stopped)"
      }
      ;;
    desktop_windows)
      env DISPLAY="${DISPLAY:-:1}" wmctrl -lx 2>&1 || true
      ;;
    launch_krita)
      if pgrep -x krita >/dev/null 2>&1; then
        echo "Krita already running."
      else
        nohup env DISPLAY="${DISPLAY:-:1}" \
          LIBGL_ALWAYS_SOFTWARE=1 QT_XCB_GL_INTEGRATION=none \
          krita >"$LOG/krita.log" 2>&1 &
        echo "Krita launch requested; pid=$!"
      fi
      ;;
    focus_krita)
      env DISPLAY="${DISPLAY:-:1}" wmctrl -a Krita 2>&1
      ;;
    stop_krita)
      if pgrep -x krita >/dev/null 2>&1; then
        pkill -TERM -x krita
        echo "Krita termination requested."
      else
        echo "Krita is not running."
      fi
      ;;
    snapshot)
      local shot="$HUB/latest-desktop.jpg"
      env DISPLAY="${DISPLAY:-:1}" scrot -z -q 45 -o "$shot"
      echo "path=$shot"
      echo "bytes=$(stat -c %s "$shot")"
      echo "sha256=$(sha256sum "$shot" | awk '{print $1}')"
      ;;

    gba_setup)
      if ! command -v google-chrome >/dev/null 2>&1; then
        echo "Installing Google Chrome..."
        tmpdeb="$(mktemp --suffix=.deb)"
        curl -fL --retry 3 --connect-timeout 20 \
          -o "$tmpdeb" \
          "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
        sudo apt-get update
        sudo apt-get install -y "$tmpdeb"
        rm -f "$tmpdeb"
      fi
      mkdir -p "$HUB/gba-chrome"
      if ! pgrep -f 'google-chrome.*gba-chrome' >/dev/null 2>&1; then
        nohup env DISPLAY="${DISPLAY:-:1}" \
          google-chrome \
          --no-sandbox \
          --disable-dev-shm-usage \
          --disable-gpu \
          --disable-software-rasterizer=false \
          --user-data-dir="$HUB/gba-chrome" \
          --window-size=1000,700 \
          --app="https://gba.js.org/player/#pokemongreen" \
          >"$LOG/gba-chrome.log" 2>&1 &
        echo "GBA browser launch requested; pid=$!"
      else
        echo "GBA browser already running."
      fi
      sleep 10
      gba_focus
      env DISPLAY="${DISPLAY:-:1}" wmctrl -lx 2>&1 | tail -n 20
      ;;
    gba_open)
      if ! command -v google-chrome >/dev/null 2>&1; then
        echo "Google Chrome is not installed; run gba_setup first." >&2
        return 65
      fi
      pkill -TERM -f 'google-chrome.*gba-chrome' >/dev/null 2>&1 || true
      sleep 2
      nohup env DISPLAY="${DISPLAY:-:1}" \
        google-chrome \
        --no-sandbox \
        --disable-dev-shm-usage \
        --disable-gpu \
        --user-data-dir="$HUB/gba-chrome" \
        --window-size=1000,700 \
        --app="https://gba.js.org/player/#pokemongreen" \
        >"$LOG/gba-chrome.log" 2>&1 &
      sleep 8
      gba_focus
      echo "GBA Online opened."
      ;;
    gba_status)
      echo "chrome=$(pgrep -f 'google-chrome.*gba-chrome' >/dev/null 2>&1 && echo running || echo stopped)"
      env DISPLAY="${DISPLAY:-:1}" wmctrl -lx 2>&1 | tail -n 20
      ;;
    gba_frame)
      gba_frame
      ;;
    gba_play)
      gba_key p
      echo "pressed=PLAY"
      ;;
    gba_up)
      gba_key Up
      echo "pressed=UP"
      ;;
    gba_down)
      gba_key Down
      echo "pressed=DOWN"
      ;;
    gba_left)
      gba_key Left
      echo "pressed=LEFT"
      ;;
    gba_right)
      gba_key Right
      echo "pressed=RIGHT"
      ;;
    gba_a)
      gba_key z
      echo "pressed=A"
      ;;
    gba_b)
      gba_key x
      echo "pressed=B"
      ;;
    gba_l)
      gba_key a
      echo "pressed=L"
      ;;
    gba_r)
      gba_key s
      echo "pressed=R"
      ;;
    gba_start)
      gba_key Return
      echo "pressed=START"
      ;;
    gba_select)
      gba_key BackSpace
      echo "pressed=SELECT"
      ;;
    *)
      echo "unsupported action: $name" >&2
      return 64
      ;;
  esac
}

while true; do
  PAYLOAD="$(CLIENT_ID="$CLIENT_ID" \
    RESULT_ACTION_ID="$RESULT_ACTION_ID" \
    RESULT_ACTION="$RESULT_ACTION" \
    RESULT_OK="$RESULT_OK" \
    RESULT_OUTPUT="$RESULT_OUTPUT" \
    python3 - <<'PY'
import json, os, socket, time
payload = {
    "client_id": os.environ.get("CLIENT_ID", ""),
    "hostname": socket.gethostname(),
    "status": "online",
    "ts": int(time.time()),
}
rid = os.environ.get("RESULT_ACTION_ID", "")
if rid:
    payload["result"] = {
        "action_id": rid,
        "action": os.environ.get("RESULT_ACTION", ""),
        "ok": os.environ.get("RESULT_OK", "") == "1",
        "output": os.environ.get("RESULT_OUTPUT", "")[:20000],
    }
print(json.dumps(payload))
PY
)"

  RESPONSE="$(curl -fsS --max-time 20 \
    -H 'Content-Type: application/json' \
    --data-binary "$PAYLOAD" \
    "$HOOK" 2>>"$LOG/make-poller-error.log" || true)"

  ACTION_ID="$(printf '%s' "$RESPONSE" | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin); a=d.get("action") or {}; print(a.get("id",""))
except Exception: print("")' 2>/dev/null)"
  ACTION_NAME="$(printf '%s' "$RESPONSE" | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin); a=d.get("action") or {}; print(a.get("name",""))
except Exception: print("")' 2>/dev/null)"

  RESULT_ACTION_ID=""
  RESULT_ACTION=""
  RESULT_OK=""
  RESULT_OUTPUT=""

  if [ -n "$ACTION_ID" ] && [ -n "$ACTION_NAME" ] && [ "$ACTION_ID" != "$LAST_ACTION_ID" ]; then
    LAST_ACTION_ID="$ACTION_ID"
    printf '%s' "$LAST_ACTION_ID" > "$LAST_ACTION_FILE"

    TMP="$(mktemp)"
    if run_action "$ACTION_NAME" >"$TMP" 2>&1; then
      RC=0
      OK=1
    else
      RC=$?
      OK=0
    fi
    OUT="$(head -c 20000 "$TMP")"
    rm -f "$TMP"

    RESULT_ACTION_ID="$ACTION_ID"
    RESULT_ACTION="$ACTION_NAME"
    RESULT_OK="$OK"
    RESULT_OUTPUT="$OUT"

    printf '[%s] action_id=%s action=%s rc=%s\n%s\n' \
      "$(date -Is)" "$ACTION_ID" "$ACTION_NAME" "$RC" "$OUT" \
      >> "$LOG/actions.log"
  fi

  sleep 5
done
