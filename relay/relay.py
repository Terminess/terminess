"""Terminess push relay.

terminessd on a user's machine POSTs here when a session needs them; this
forwards it to Apple Push Notification service with the app's push key.
It stores nothing and logs no message content.

POST /v1/register {"token", "environment"}                 sends the phone a challenge
POST /v1/confirm  {"token", "environment", "challenge"}    returns {"credential"}
POST /v1/notify   {"token", "environment", "credential", "body", "session", "host"}
POST /v1/revoke   {"token", "environment", "credential"}   a lost phone: cancels its credentials
GET  /health

Registration: the phone asks for a challenge, which only reaches it through
Apple, and sends it back; that proves it owns the token, and the relay returns
a credential (an HMAC over the token, environment and expiry, made with the
relay's secret, so nothing is stored). The phone gives it to its machines over
SSH and they include it with each notification. Once every client has one,
REQUIRE_CREDENTIAL=1 makes it mandatory, so made-up tokens never reach Apple.

Notifications only ever say one of a few fixed things (see BODIES): whatever
text a request carries, the relay sends one of those, so it can't be used to
put arbitrary words on someone's phone. Requests are checked strictly and
limited per device, per sender address and overall; tokens Apple has rejected
are refused without asking Apple again.
"""
import base64
import hashlib
import hmac
import json
import os
import secrets
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
ID_RE = re.compile(r"^[A-Za-z0-9-]{0,64}$")
LIMIT_PER_MINUTE = 20
LIMIT_PER_SENDER = 60
LIMIT_OVERALL = 1200
MAX_TRACKED = 50_000
MAX_CONCURRENT = 32
READ_TIMEOUT = 10
BODIES = {"A session finished", "A session needs you", "A session stopped on an error", "A session needs your approval"}
APPROVAL_BODY = "A session needs your approval"
DEFAULT_BODY = "A session needs you"

SECRET = os.environ.get("RELAY_SECRET", "").encode()
REQUIRE_CREDENTIAL = os.environ.get("REQUIRE_CREDENTIAL") == "1"
REVOKED_FILE = os.path.join(os.environ.get("STATE_DIRECTORY", "/var/lib/terminess-relay"), "revoked.json")
CHALLENGE_SECONDS = 300
CREDENTIAL_SECONDS = 365 * 24 * 3600
_key = open(KEY_PATH).read()
_jwt = {"value": "", "made": 0.0}
_jwt_lock = threading.Lock()
_recent: dict[str, list[float]] = {}
_overall: list[float] = []
_rejected: dict[str, float] = {}
_recent_lock = threading.Lock()
_slots = threading.BoundedSemaphore(MAX_CONCURRENT)
_client = httpx.Client(http2=True, timeout=10)


def auth_token() -> str:
    """Apple accepts a provider token for up to an hour; refresh every 40 minutes."""
    with _jwt_lock:
        if time.time() - _jwt["made"] > 40 * 60:
            _jwt["value"] = jwt.encode({"iss": TEAM_ID, "iat": int(time.time())}, _key, algorithm="ES256",
                                       headers={"kid": KEY_ID})
            _jwt["made"] = time.time()
        return _jwt["value"]


def allowed(key: str, limit: int) -> bool:
    """A sliding one-minute window per key, with a hard cap on how many keys are tracked."""
    now = time.time()
    with _recent_lock:
        times = [t for t in _recent.get(key, []) if now - t < 60]
        if len(times) >= limit:
            _recent[key] = times
            return False
        if key not in _recent and len(_recent) >= MAX_TRACKED:
            for k in [k for k, v in _recent.items() if not v or now - v[-1] > 60]:
                _recent.pop(k, None)
            if len(_recent) >= MAX_TRACKED:
                return False
        times.append(now)
        _recent[key] = times
        return True


def allowed_overall() -> bool:
    now = time.time()
    with _recent_lock:
        _overall[:] = [t for t in _overall if now - t < 60]
        if len(_overall) >= LIMIT_OVERALL:
            return False
        _overall.append(now)
        return True


def was_rejected(token: str) -> bool:
    with _recent_lock:
        when = _rejected.get(token)
        return when is not None and time.time() - when < 24 * 3600


def remember_rejected(token: str):
    with _recent_lock:
        if len(_rejected) >= MAX_TRACKED:
            cutoff = time.time() - 24 * 3600
            for k in [k for k, v in _rejected.items() if v < cutoff]:
                _rejected.pop(k, None)
            if len(_rejected) >= MAX_TRACKED:
                _rejected.pop(next(iter(_rejected)))
        _rejected[token] = time.time()


def _load_revoked() -> dict[str, float]:
    try:
        with open(REVOKED_FILE) as f:
            data = json.load(f)
        return {k: float(v) for k, v in data.items() if isinstance(k, str)} if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


_revoked = _load_revoked()
_revoked_lock = threading.Lock()


def revoke_token(token: str):
    with _revoked_lock:
        _revoked[token] = time.time()
        if len(_revoked) > MAX_TRACKED:
            cutoff = time.time() - CREDENTIAL_SECONDS
            for k in [k for k, v in _revoked.items() if v < cutoff]:
                _revoked.pop(k, None)
        tmp = REVOKED_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(_revoked, f)
        os.replace(tmp, REVOKED_FILE)


def revoked_before(token: str) -> float:
    with _revoked_lock:
        return _revoked.get(token, 0.0)


def text(req: dict, key: str, default: str = "") -> str | None:
    """A string field, or None when it's there but isn't a string."""
    v = req.get(key, default)
    return v if isinstance(v, str) else None


def _mac(purpose: str, *parts: str) -> str:
    msg = "\n".join((purpose,) + parts).encode()
    return base64.urlsafe_b64encode(hmac.new(SECRET, msg, hashlib.sha256).digest()).decode().rstrip("=")


def make_challenge(token: str, env: str) -> str:
    expiry = str(int(time.time()) + CHALLENGE_SECONDS)
    nonce = secrets.token_urlsafe(9)
    return f"{nonce}.{expiry}.{_mac('challenge-v1', token, env, TOPIC, nonce, expiry)}"


def check_challenge(token: str, env: str, challenge: str) -> bool:
    parts = challenge.split(".")
    if len(parts) != 3 or not parts[1].isdigit() or int(parts[1]) < time.time():
        return False
    return hmac.compare_digest(parts[2], _mac("challenge-v1", token, env, TOPIC, parts[0], parts[1]))


def make_credential(token: str, env: str) -> str:
    cid = secrets.token_urlsafe(9)
    expiry = str(int(time.time()) + CREDENTIAL_SECONDS)
    return f"v1.{cid}.{expiry}.{_mac('credential-v1', token, env, TOPIC, cid, expiry)}"


def check_credential(token: str, env: str, credential: str) -> bool:
    parts = credential.split(".")
    if len(parts) != 4 or parts[0] != "v1" or not parts[2].isdigit() or int(parts[2]) < time.time():
        return False
    if int(parts[2]) - CREDENTIAL_SECONDS < revoked_before(token):
        return False
    return hmac.compare_digest(parts[3], _mac("credential-v1", token, env, TOPIC, parts[1], parts[2]))


def apns(token: str, env: str, payload: dict, collapse: str) -> tuple[int, str]:
    headers = {
        "authorization": f"bearer {auth_token()}",
        "apns-topic": TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-collapse-id": collapse,
    }
    r = _client.post(f"{HOSTS[env]}/3/device/{token}", json=payload, headers=headers)
    if r.status_code == 200:
        return 200, "sent"
    try:
        reason = r.json().get("reason", "")
    except ValueError:
        reason = ""
    if r.status_code == 410 or reason in ("BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"):
        remember_rejected(token)
        return 410, reason or "gone"
    return 502, reason or str(r.status_code)


def token_env(req: dict) -> tuple[str, str] | None:
    token, env = text(req, "token"), text(req, "environment", "production")
    if token is None or env is None:
        return None
    token = token.lower()
    if not TOKEN_RE.match(token) or env not in HOSTS:
        return None
    return token, env


def register(req: dict, sender: str = "") -> tuple[int, str]:
    """Sends a challenge that only the phone holding the token can see."""
    te = token_env(req)
    if te is None:
        return 400, "bad token or environment"
    token, env = te
    if not SECRET:
        return 503, "registration unavailable"
    if was_rejected(token):
        return 410, "token rejected by apns"
    if not allowed("r:" + token, 3) or (sender and not allowed("rs:" + sender, 10)) or not allowed_overall():
        return 429, "too many registrations"
    payload = {"aps": {"alert": {"title": "Terminess", "body": "Turning on notifications"}}, "challenge": make_challenge(token, env)}
    return apns(token, env, payload, "terminess-register")


def confirm(req: dict) -> tuple[int, str]:
    te = token_env(req)
    challenge = text(req, "challenge")
    if te is None or challenge is None or len(challenge) > 200:
        return 400, "bad request"
    if not SECRET or not check_challenge(te[0], te[1], challenge):
        return 403, "bad or expired challenge"
    return 200, make_credential(*te)


def revoke(req: dict) -> tuple[int, str]:
    """Whoever holds a phone's credential (its machines) can cancel it."""
    te = token_env(req)
    credential = text(req, "credential")
    if te is None or not credential or not SECRET or not check_credential(te[0], te[1], credential[:300]):
        return 403, "bad credential"
    revoke_token(te[0])
    return 200, "revoked"


def send(req: dict, sender: str = "") -> tuple[int, str]:
    token, env = text(req, "token"), text(req, "environment", "production")
    body, session, host = text(req, "body"), text(req, "session"), text(req, "host")
    if token is None or env is None or body is None or session is None or host is None:
        return 400, "bad field"
    token = token.lower()
    if not TOKEN_RE.match(token) or env not in HOSTS:
        return 400, "bad token or environment"
    if not ID_RE.match(session) or not ID_RE.match(host):
        return 400, "bad session or host"
    credential = text(req, "credential")
    if credential is None:
        return 400, "bad field"
    if credential:
        if not SECRET or not check_credential(token, env, credential[:300]):
            return 401, "bad credential"
    elif REQUIRE_CREDENTIAL:
        return 401, "credential required"
    if was_rejected(token):
        return 410, "token rejected by apns"
    if not allowed("t:" + token, LIMIT_PER_MINUTE) or (sender and not allowed("s:" + sender, LIMIT_PER_SENDER)):
        return 429, "too many notifications"
    if not allowed_overall():
        return 503, "busy"
    title = "Terminess"
    body = body if body in BODIES else DEFAULT_BODY
    payload = {
        "aps": {"alert": {"title": title, "body": body}, "sound": "default", "thread-id": session or "terminess",
                **({"category": "APPROVAL"} if body == APPROVAL_BODY else {})},
        "session": session,
        "host": host,
    }
    return apns(token, env, payload, session[:64] or "terminess")


class Handler(BaseHTTPRequestHandler):
    server_version = "terminess-relay"
    timeout = READ_TIMEOUT

    def reply(self, code: int, message: str, **extra):
        data = json.dumps({"result": message, **extra}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(200, "ok") if self.path == "/health" else self.reply(404, "not found")

    def do_POST(self):
        if self.path not in ("/v1/notify", "/v1/register", "/v1/confirm", "/v1/revoke"):
            return self.reply(404, "not found")
        raw = self.headers.get("Content-Length", "")
        if not raw.isascii() or not raw.isdigit():
            return self.reply(400, "bad length")
        length = int(raw)
        if length <= 0 or length > 4096:
            return self.reply(413, "too large")
        if not _slots.acquire(blocking=False):
            return self.reply(503, "busy")
        try:
            try:
                req = json.loads(self.rfile.read(length))
            except (ValueError, OSError):
                return self.reply(400, "bad json")
            if not isinstance(req, dict):
                return self.reply(400, "bad json")
            sender = self.headers.get("CF-Connecting-IP", "")[:64] or self.client_address[0]
            try:
                if self.path == "/v1/register":
                    code, message = register(req, sender)
                elif self.path == "/v1/revoke":
                    code, message = revoke(req)
                elif self.path == "/v1/confirm":
                    code, message = confirm(req)
                    if code == 200:
                        return self.reply(200, "ok", credential=message)
                else:
                    code, message = send(req, sender)
            except httpx.HTTPError:
                code, message = 502, "apns unreachable"
            self.reply(code, message)
        finally:
            _slots.release()

    def log_message(self, fmt, *args):
        if args and str(args[0]).startswith("POST"):
            path = str(args[0]).split(" ")[1] if " " in str(args[0]) else ""
            print(f"{path} -> {args[1]}", flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
