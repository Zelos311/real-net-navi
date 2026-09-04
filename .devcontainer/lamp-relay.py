#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
import hmac
import json
import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import urlparse

HOST = "0.0.0.0"
PORT = int(os.environ.get("LAMP_HUB_PORT", "8787"))
TOKEN = os.environ["LAMP_HUB_TOKEN"]
DISPLAY = os.environ.get("DISPLAY", ":1")
HOME = str(Path.home())
HUB = Path(HOME) / ".lamp-hub"
LOG = HUB / "logs"
STARTED = time.time()
HANDSHAKE_FILE = HUB / "handshake.json"

def action_env():
    env = os.environ.copy()
    env["DISPLAY"] = DISPLAY
    env.setdefault("LIBGL_ALWAYS_SOFTWARE", "1")
    env.setdefault("QT_XCB_GL_INTEGRATION", "none")
    return env

def run_fixed(argv, timeout=30):
    proc = subprocess.run(
        argv,
        cwd=HOME,
        env=action_env(),
        text=True,
        capture_output=True,
        timeout=timeout,
        shell=False,
    )
    return {
        "ok": proc.returncode == 0,
        "returncode": proc.returncode,
        "stdout": proc.stdout[-20000:],
        "stderr": proc.stderr[-20000:],
    }

def is_running(name):
    return subprocess.run(
        ["pgrep", "-x", name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0

def run_action(name):
    if name == "hub_status":
        return {
            "ok": True,
            "codespace": os.environ.get("CODESPACE_NAME"),
            "hostname": os.uname().nodename,
            "display": DISPLAY,
            "uptime_seconds": int(time.time() - STARTED),
            "krita": "running" if is_running("krita") else "stopped",
        }

    if name == "desktop_windows":
        return run_fixed(["wmctrl", "-lx"])

    if name == "launch_krita":
        if is_running("krita"):
            return {"ok": True, "message": "Krita already running."}
        LOG.mkdir(parents=True, exist_ok=True)
        out = open(LOG / "krita.log", "ab", buffering=0)
        proc = subprocess.Popen(
            ["krita"],
            cwd=HOME,
            env=action_env(),
            stdout=out,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        out.close()
        return {"ok": True, "message": "Krita launch requested.", "pid": proc.pid}

    if name == "focus_krita":
        return run_fixed(["wmctrl", "-a", "Krita"])

    if name == "stop_krita":
        if not is_running("krita"):
            return {"ok": True, "message": "Krita is not running."}
        proc = subprocess.run(["pkill", "-TERM", "-x", "krita"], check=False)
        return {"ok": proc.returncode == 0, "message": "Krita termination requested."}

    if name == "snapshot":
        shot = HUB / "latest-desktop.jpg"
        result = run_fixed(["scrot", "-z", "-q", "45", "-o", str(shot)], timeout=20)
        if not result["ok"]:
            return result
        data = shot.read_bytes()
        return {
            "ok": True,
            "path": str(shot),
            "bytes": len(data),
        }

    raise ValueError("unsupported action")

class Handler(BaseHTTPRequestHandler):
    server_version = "LampHubRelay/0.2"

    def _headers(self, status=200, ctype="application/json; charset=utf-8", length=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        if length is not None:
            self.send_header("Content-Length", str(length))
        self.end_headers()

    def _json(self, obj, status=200):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self._headers(status, length=len(data))
        self.wfile.write(data)

    def _authorized(self):
        header = self.headers.get("Authorization", "")
        prefix = "Bearer "
        if not header.startswith(prefix):
            return False
        supplied = header[len(prefix):]
        return hmac.compare_digest(supplied, TOKEN)

    def _require_auth(self):
        if not self._authorized():
            self._json({"error": "unauthorized"}, 401)
            return False
        return True

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            self._json({
                "status": "ok",
                "codespace": os.environ.get("CODESSPACE_NAME"),
                "display": DISPLAY,
                "uptime_seconds": int(time.time() - STARTED),
                "actions": [
                    "hub_status", "desktop_windows", "launch_krita",
                    "focus_krita", "stop_krita", "snapshot"
                ],
            })
            return

        if path == "/handshake":
            try:
                data = json.loads(HANDSHAKE_FILE.read_text())
                self._json(data)
            except Exception as exc:
                self._json({"error": f"handshake unavailable: {exc}"}, 503)
            return

        if path == "/screenshot":
            if not self._require_auth():
                return
            env = action_env()
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
                shot = tmp.name
            try:
                subprocess.run(
                    ["scrot", "-z", "-o", shot],
                    env=env, check=True, timeout=20, shell=False
                )
                data = Path(shot).read_bytes()
                self._headers(200, "image/png", len(data))
                self.wfile.write(data)
            except Exception as exc:
                self._json({"error": str(exc)}, 500)
            finally:
                try:
                    os.unlink(shot)
                except OSError:
                    pass
            return

        if path == "/screenshot-json":
            if not self._require_auth():
                return
            env = action_env()
            with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
                shot = tmp.name
            try:
                subprocess.run(
                    ["scrot", "-z", "-q", "55", "-o", shot],
                    env=env, check=True, timeout=20, shell=False
                )
                data = Path(shot).read_bytes()
                self._json({
                    "mime": "image/jpeg",
                    "base64": base64.b64encode(data).decode("ascii"),
                })
            except Exception as exc:
                self._json({"error": str(exc)}, 500)
            finally:
                try:
                    os.unlink(shot)
                except OSError:
                    pass
            return

        self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = urlparse(self.path).path
        if not self._require_auth():
            return

        length = int(self.headers.get("Content-Length", "0"))
        if length > 20_000:
            self._json({"error": "request too large"}, 413)
            return
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            self._json({"error": "invalid json"}, 400)
            return

        if path == "/action":
            name = body.get("name", "")
            try:
                self._json(run_action(name))
            except ValueError as exc:
                self._json({"error": str(exc)}, 400)
            except subprocess.TimeoutExpired:
                self._json({"error": "action timed out"}, 408)
            except Exception as exc:
                self._json({"error": str(exc)}, 500)
            return

        # Deliberately no generic /exec endpoint.
        self._json({"error": "not found"}, 404)

    def log_message(self, fmt, *args):
        print("[%s] %s" % (self.log_date_time_string(), fmt % args), flush=True)

if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
