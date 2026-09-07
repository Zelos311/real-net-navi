from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import json
import os
import subprocess
import time

DISPLAY = os.environ.get("DISPLAY", ":99")
TOKEN = os.environ["CONTROL_TOKEN"]
GAME_URL = os.environ.get("GAME_URL", "https://gba.js.org/player/#pokemongreen")

KEYMAP = {
    "gba_play": "p",
    "gba_up": "Up",
    "gba_down": "Down",
    "gba_left": "Left",
    "gba_right": "Right",
    "gba_a": "z",
    "gba_b": "x",
    "gba_l": "a",
    "gba_r": "s",
    "gba_start": "Return",
    "gba_select": "BackSpace",
}

def action_env():
    env = os.environ.copy()
    env["DISPLAY"] = DISPLAY
    return env

def focus_game():
    for name in ["GBA Online", "pokemon", "Pokémon", "Google Chrome", "Chromium"]:
        found = subprocess.run(
            ["xdotool", "search", "--onlyvisible", "--name", name],
            env=action_env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        ids = [value for value in found.stdout.splitlines() if value.strip()]
        if ids:
            subprocess.run(
                ["xdotool", "windowactivate", "--sync", ids[-1]],
                env=action_env(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            return True
    return False

def capture_frame():
    png = "/tmp/genie-gba/frame.png"
    jpg = "/tmp/genie-gba/frame.jpg"
    subprocess.run(["scrot", "-z", "-o", png], env=action_env(), check=True, timeout=10)
    subprocess.run(
        ["convert", png, "-resize", "640x360>", "-quality", "42", jpg],
        check=True,
        timeout=10,
    )
    with open(jpg, "rb") as handle:
        return handle.read()

class Handler(BaseHTTPRequestHandler):
    server_version = "GenieGBA/1.0"

    def log_message(self, fmt, *args):
        return

    def authorized(self):
        query = parse_qs(urlparse(self.path).query)
        supplied = self.headers.get("X-Genie-Key", "") or query.get("token", [""])[0]
        return supplied == TOKEN

    def send_json(self, obj, status=200):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            self.send_json({"ok": True, "display": DISPLAY, "game_url": GAME_URL})
            return
        if path == "/frame.jpg":
            if not self.authorized():
                self.send_json({"ok": False, "error": "unauthorized"}, 401)
                return
            try:
                data = capture_frame()
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as exc:
                self.send_json({"ok": False, "error": str(exc)}, 500)
            return
        self.send_json({"ok": False, "error": "not_found"}, 404)

    def do_POST(self):
        if urlparse(self.path).path != "/action":
            self.send_json({"ok": False, "error": "not_found"}, 404)
            return
        if not self.authorized():
            self.send_json({"ok": False, "error": "unauthorized"}, 401)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
            action = body.get("action", "")
            if action in KEYMAP:
                focus_game()
                time.sleep(0.08)
                subprocess.run(
                    ["xdotool", "key", "--clearmodifiers", KEYMAP[action]],
                    env=action_env(),
                    check=True,
                    timeout=5,
                )
                self.send_json({"ok": True, "action": action})
                return
            if action == "focus":
                self.send_json({"ok": focus_game(), "action": action})
                return
            if action == "click_center":
                focus_game()
                subprocess.run(
                    ["xdotool", "mousemove", "640", "360", "click", "1"],
                    env=action_env(),
                    check=True,
                    timeout=5,
                )
                self.send_json({"ok": True, "action": action})
                return
            self.send_json({"ok": False, "error": "unsupported_action"}, 400)
        except Exception as exc:
            self.send_json({"ok": False, "error": str(exc)}, 500)

ThreadingHTTPServer(("127.0.0.1", 8777), Handler).serve_forever()
