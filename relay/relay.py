"""Terminess push relay.

terminessd on a user's machine POSTs here when a session needs them; this
forwards it to Apple Push Notification service with the app's push key.
It stores nothing and logs no message content.

POST /v1/notify  {"token", "environment": "sandbox"|"production", "title", "body", "session", "host"}
GET  /health
"""
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import httpx
import jwt

KEY_PATH = os.environ["APNS_KEY_PATH"]
KEY_ID = os.environ["APNS_KEY_ID"]
TEAM_ID = os.environ["APNS_TEAM_ID"]
TOPIC = os.environ.get("APNS_TOPIC", "com.nsokin.terminal.ios")
PORT = int(os.environ.get("PORT", "8099"))
HOSTS = {"sandbox": "https://api.sandbox.push.apple.com", "production": "https://api.push.apple.com"}
TOKEN_RE = re.compile(r"^[0-9a-f]{64,200}$")
LIMIT_PER_MINUTE = 20

_key = open(KEY_PATH).read()
_jwt = {"value": "", "made": 0.0}
_jwt_lock = threading.Lock()
_recent: dict[str, list[float]] = {}
_recent_lock = threading.Lock()
_client = httpx.Client(http2=True, timeout=10)


def auth_token() -> str:
    """Apple accepts a provider token for up to an hour; refresh every 40 minutes."""
    with _jwt_lock:
        if time.time() - _jwt["made"] > 40 * 60:
            _jwt["value"] = jwt.encode({"iss": TEAM_ID, "iat": int(time.time())}, _key, algorithm="ES256",
                                       headers={"kid": KEY_ID})
            _jwt["made"] = time.time()
        return _jwt["value"]


def allowed(token: str) -> bool:
    now = time.time()
    with _recent_lock:
        times = [t for t in _recent.get(token, []) if now - t < 60]
        if len(times) >= LIMIT_PER_MINUTE:
            _recent[token] = times
            return False
        times.append(now)
        _recent[token] = times
        if len(_recent) > 10_000:
            for k in [k for k, v in _recent.items() if not v or now - v[-1] > 60]:
                _recent.pop(k, None)
        return True


def send(req: dict) -> tuple[int, str]:
    token = str(req.get("token", "")).lower()
    env = req.get("environment", "production")
    if not TOKEN_RE.match(token) or env not in HOSTS:
        return 400, "bad token or environment"
    if not allowed(token):
        return 429, "too many notifications"
    title = str(req.get("title", "Terminess"))[:120]
    body = str(req.get("body", ""))[:400]
    session = str(req.get("session", ""))[:64]
    host = str(req.get("host", ""))[:64]
    payload = {
        "aps": {"alert": {"title": title, "body": body}, "sound": "default", "thread-id": session or "terminess"},
        "session": session,
        "host": host,
    }
    headers = {
        "authorization": f"bearer {auth_token()}",
        "apns-topic": TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-collapse-id": session[:64] or "terminess",
    }
    r = _client.post(f"{HOSTS[env]}/3/device/{token}", json=payload, headers=headers)
    if r.status_code == 200:
        return 200, "sent"
    try:
        reason = r.json().get("reason", "")
    except ValueError:
        reason = ""
    return (410 if r.status_code == 410 or reason == "BadDeviceToken" else 502), reason or str(r.status_code)


class Handler(BaseHTTPRequestHandler):
    server_version = "terminess-relay"

    def reply(self, code: int, message: str):
        data = json.dumps({"result": message}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(200, "ok") if self.path == "/health" else self.reply(404, "not found")

    def do_POST(self):
        if self.path != "/v1/notify":
            return self.reply(404, "not found")
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > 4096:
            return self.reply(413, "too large")
        try:
            req = json.loads(self.rfile.read(length))
        except ValueError:
            return self.reply(400, "bad json")
        try:
            code, message = send(req if isinstance(req, dict) else {})
        except httpx.HTTPError:
            code, message = 502, "apns unreachable"
        self.reply(code, message)

    def log_message(self, fmt, *args):
        if args and str(args[0]).startswith("POST"):
            print(f"notify -> {args[1]}", flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
