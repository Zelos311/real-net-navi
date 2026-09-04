#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
import hmac
import json
import os
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
STARTED = time.time()
HANDSHAKE_FILE = Path(HOME) / ".lamp-hub" / "handshake.json"

def run_command(command, timeout=60, cwd=None):
    timeout = max(1, min(int(timeout), 120))
    if not isinstance(command, str) or not command.strip():
        raise ValueError("command must be a non-empty string")
    if len(command) > 20000:
        raise ValueError("command too long")
    env = os.environ.copy()
    env["DISPLAY"] = DISPLAY
    env.setdefault("LIBGL_ALWAYS_SOFTWARE", "1")
    env.setdefault("QT_XCB_GL_INTEGRATION", "none")
    proc = subprocess.run(
        command,
        shell=True,
        cwd=cwd or HOME,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    limit = 1_000_000
    return {
        "returncode": proc.returncode,
        "stdout": proc.stdout[-limit:],
        "stderr": proc.stderr[-limit:],
    }

class Handler(BaseHTTPRequestHandler):
    server_version = "LampHubRelay/0.1"

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
                "codespace": os.environ.get("CODESPACE_NAME"),
                "display": DISPLAY,
                "uptime_seconds": int(time.time() - STARTED),
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
            env = os.environ.copy()
            env["DISPLAY"] = DISPLAY
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
                shot = tmp.name
            try:
                subprocess.run(["scrot", "-z", "-o", shot], env=env, check=True, timeout=20)
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
            env = os.environ.copy()
            env["DISPLAY"] = DISPLAY
            with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
                shot = tmp.name
            try:
                subprocess.run(
                    ["scrot", "-z", "-q", "55", "-o", shot],
                    env=env, check=True, timeout=20
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
        if length > 100_000:
            self._json({"error": "request too large"}, 413)
            return
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            self._json({"error": "invalid json"}, 400)
            return

        if path == "/exec":
            try:
                result = run_command(
                    body.get("command", ""),
                    timeout=body.get("timeout", 60),
                    cwd=body.get("cwd") or HOME,
                )
                self._json(result)
            except subprocess.TimeoutExpired:
                self._json({"error": "command timed out"}, 408)
            except Exception as exc:
                self._json({"error": str(exc)}, 400)
            return

        self._json({"error": "not found"}, 404)

    def log_message(self, fmt, *args):
        # Keep logs useful without echoing credentials or request bodies.
        print("[%s] %s" % (self.log_date_time_string(), fmt % args), flush=True)

if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
