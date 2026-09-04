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

echo "[Lamp Hub] Make heartbeat starting as $CLIENT_ID"

while true; do
  PAYLOAD="$(CLIENT_ID="$CLIENT_ID" python3 - <<'PY'
import json, os, socket, time
print(json.dumps({
    "client_id": os.environ.get("CLIENT_ID", ""),
    "hostname": socket.gethostname(),
    "status": "online",
    "ts": int(time.time())
}))
PY
)"

  curl -fsS --max-time 20 \
    -H 'Content-Type: application/json' \
    --data-binary "$PAYLOAD" \
    "$HOOK" >>"$HUB/logs/make-heartbeat.log" 2>>"$HUB/logs/make-heartbeat-error.log" || true
  printf '\n' >>"$HUB/logs/make-heartbeat.log"
  sleep 5
done
