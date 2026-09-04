#!/usr/bin/env bash
set -u

HOOK="${1:-${LAMP_HUB_HOOK:-}}"
if [ -z "$HOOK" ]; then
  echo "Usage: $0 <make-webhook-url>" >&2
  exit 2
fi

HUB="$HOME/.lamp-hub"
mkdir -p "$HUB/logs"

CLIENT_FILE="$HUB/client-id"
if [ ! -s "$CLIENT_FILE" ]; then
  python3 - <<'PY' > "$CLIENT_FILE"
import uuid
print(uuid.uuid4())
PY
fi
CLIENT_ID="$(cat "$CLIENT_FILE")"

LAST_ID_FILE="$HUB/last-command-id"
LAST_ID="$(cat "$LAST_ID_FILE" 2>/dev/null || true)"
RESUL_ID=""
RESULT_RC=""
RESULT_OUT=""
RESUL_STATUS="online"

echo "[Lamp Hub] outbound command socket starting as $CLIENT_ID"

while true; do
  PAYLOAD="$(CLIENT_ID="$CLIENT_ID" RESULT_ID="$RESULT_ID" RESULT_RC="$RESULT_RC" RESULT_OUT="$RESULT_OUT" RESULT_STATUS="$RESULT_STATUS" python3 - <<'PY'
import json, os, socket, time
print(json.dumps({
    "client_id": os.environ.get("CLIENT_ID",""),
    "hostname": socket.gethostname(),
    "status": os.environ.get("RESULT_STATUS","online"),
    "result_command_id": os.environ.get("RESULT_ID",""),
    "exit_code": os.environ.get("RESULT_RC",""),
    "output": os.environ.get("RESULT_OUT","")[:20000],
    "ts": int(time.time())
}))
PY
)"

  RESPONSE="$(curl -fsS --max-time 20 \
    -H 'Content-Type: application/json' \
    --data-binary "$PAYLOAD" \
    "$HOOK" 2>>"$HUB/logs/poller-curl.log" || true)"

  CMD_ID="$(printf '%s' "$RESPONSE" | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin); print(d.get("id",""))
except Exception: print("")' 2>/dev/null)"
  CMD="$(printf '%s' "$RESPONSE" | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin); print(d.get("command",""))
except Exception: print("")' 2>/dev/null)"

  RESULT_ID=""
  RESULT_RC=""
  RESULT_OUT=""
  RESULT_STATUS="idle"

  if [ -n "$CMD_ID" ] && [ -n "$CMD" ] && [ "$CMD_ID" != "$LAST_ID" ]; then
    TMP="$(mktemp)"
    set +e
    bash -lc "$CMD" >"$TMP" 2>&1
    RC=$?
    set -e
    OUT="$(head -c 20000 "$TMP")"
    rm -f "$TMP"

    RESULT_ID="$CMD_ID" 
    RESULT_RC="$RC"
    RESULT_OUT="$OUT"
    RESULT_STATUS="command_complete"
    LAST_ID="$CMD_ID" 
    printf '%s' "$LAST_ID" > "$LAST_ID_FILE"
    printf '[%s] id=%s rc=%s\n%s\n' "$(date -Is)" "$CMDID" "$RC" "$OUT" >> "$HUB/logs/commands.log"
  fi

  sleep 3
done
