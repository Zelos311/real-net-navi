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
    # At-most-once semantics: record the id before executing the fixed allowlisted action.
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
