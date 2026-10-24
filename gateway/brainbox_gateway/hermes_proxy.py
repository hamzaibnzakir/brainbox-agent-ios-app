"""Brainbox Hermes proxy: the secure front door between the iOS app and the
Hermes API Server.

    iPhone ──HTTPS (Tailscale)──▶ hermes-proxy (this) ──http://127.0.0.1:8642──▶ Hermes API Server

Why it exists
-------------
* Hermes authenticates with ONE static ``API_SERVER_KEY`` that grants
  terminal-capable agent work. That key must never be embedded in, or typed
  into, the phone. The proxy keeps it server-side (read from a root-only file)
  and gives each device its own revocable token, stored here only as a
  SHA-256 hash.
* Only the routes the app needs are forwarded (explicit allow-list). Browser
  control, artifact upload, platform callbacks, cron webhooks and the OpenAI
  compatibility endpoints are refused.
* Failed logins are rate limited per client address; every request is rate
  limited per device; mutating requests and admin actions are audit-logged
  (method, path, status, device — never bodies or secrets).
* Profile administration (list / create) is a narrow, opt-in operation that
  runs ``hermes profile create <validated-name>`` with an argument vector —
  never a shell, never arbitrary commands.

Nothing here modifies Hermes, its config, its services or its database.
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import os
import re
from urllib.parse import quote, urlsplit
import sys
import time
from collections import defaultdict, deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from aiohttp import ClientSession, ClientTimeout, web

from . import __version__
from .chat_sessions import (OwnershipRegistry, ReadOnlySessionStore, SessionStoreUnavailable, is_app_session,
                            remove_session_files)
from .commands import CommandCatalog, CommandsUnavailable
from .diagnostics import host_snapshot
from .pty_terminal import TerminalConfig, TerminalManager, TerminalUnavailable, parse_client_frame
from .push import EVENT_KINDS, Notification, PushConfig, PushService
from .workspace_files import Workspace, WorkspaceConfig, WorkspaceError, owner_dir

if sys.version_info >= (3, 11):
    import tomllib
else:  # pragma: no cover
    import tomli as tomllib

log = logging.getLogger("brainbox.hermes_proxy")

PROFILE_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
ID_RE = r"[A-Za-z0-9_.:\-]{1,256}"
JOB_RE = r"[a-f0-9]{12}"

# (method, path regex) relative to the Hermes root. Verified against
# hermes-agent v0.21.2 (gateway/platforms/api_server.py route table).
ALLOWED_ROUTES: list[tuple[str, re.Pattern[str]]] = [
    (m, re.compile(f"^{p}$")) for m, p in [
        ("GET", r"/health"), ("GET", r"/v1/health"), ("GET", r"/health/detailed"),
        ("GET", r"/v1/capabilities"), ("GET", r"/v1/models"), ("GET", r"/api/model/options"),
        ("GET", r"/v1/skills"), ("GET", r"/v1/toolsets"),
        ("GET", r"/api/sessions"), ("POST", r"/api/sessions"),
        ("GET", rf"/api/sessions/{ID_RE}"), ("PATCH", rf"/api/sessions/{ID_RE}"), ("DELETE", rf"/api/sessions/{ID_RE}"),
        ("GET", rf"/api/sessions/{ID_RE}/messages"), ("POST", rf"/api/sessions/{ID_RE}/fork"),
        ("POST", rf"/api/sessions/{ID_RE}/chat"), ("POST", rf"/api/sessions/{ID_RE}/chat/stream"),
        ("POST", r"/v1/runs"), ("GET", rf"/v1/runs/{ID_RE}"), ("GET", rf"/v1/runs/{ID_RE}/events"),
        ("POST", rf"/v1/runs/{ID_RE}/stop"), ("POST", rf"/v1/runs/{ID_RE}/steer"), ("POST", rf"/v1/runs/{ID_RE}/approval"),
        ("GET", r"/api/jobs"), ("POST", r"/api/jobs"),
        ("GET", rf"/api/jobs/{JOB_RE}"), ("PATCH", rf"/api/jobs/{JOB_RE}"), ("DELETE", rf"/api/jobs/{JOB_RE}"),
        ("POST", rf"/api/jobs/{JOB_RE}/pause"), ("POST", rf"/api/jobs/{JOB_RE}/resume"), ("POST", rf"/api/jobs/{JOB_RE}/run"),
    ]
]

# X-Hermes-Session-Id / X-Hermes-Session-Key are deliberately NOT forwarded:
# they can select an existing Hermes session, and the app never uses them.
FORWARD_REQUEST_HEADERS = ("Content-Type", "Accept", "Idempotency-Key", "Last-Event-ID")
FORWARD_RESPONSE_HEADERS = ("Content-Type", "Cache-Control", "Idempotency-Replayed", "X-Hermes-Session-Id",
                            "X-Hermes-Session-Key", "Retry-After")
PUBLIC_ROUTES = {("GET", "/health"), ("GET", "/v1/health")}

# --------------------------------------------------------------------------- session guard
# The app may only WRITE to its own sessions (`ios_` prefix, source api_server).
# Everything else — Telegram above all — is read-only through this proxy.
# Verified in Hermes 284d220: POST /api/sessions/{id}/fork ENDS the source
# session (`db.end_session(source_id, "branched")`), and a run with a
# `session_id` writes its turn into that session.
APP_SESSION_PREFIX = "ios_"
_SESSION_ITEM = re.compile(rf"^/api/sessions/({ID_RE})$")
_SESSION_WRITE_ACTION = re.compile(rf"^/api/sessions/({ID_RE})/(fork|chat|chat/stream)$")
_JOB_PATHS = re.compile(rf"^/api/jobs(/{JOB_RE})?$")
DELIVER_RE = re.compile(r"^[a-z0-9_:\-]{1,64}$")


def session_write_target(method: str, path: str, body: bytes | None) -> str | None:
    """The session a request would create or change, if any (ownership is checked on it)."""
    if method == "PATCH":
        m = _SESSION_ITEM.match(path)
        return m.group(1) if m else None
    if method != "POST":
        return None
    m = _SESSION_WRITE_ACTION.match(path)
    if m:
        return m.group(1)
    if path in ("/api/sessions", "/v1/runs"):
        try:
            data = json.loads(body) if body else {}
        except (ValueError, UnicodeDecodeError):
            return None
        if not isinstance(data, dict):
            return None
        value = (data.get("id") or data.get("session_id")) if path == "/api/sessions" else data.get("session_id")
        return value if isinstance(value, str) else None
    return None


def _is_app_session(session_id: Any) -> bool:
    return isinstance(session_id, str) and session_id.startswith(APP_SESSION_PREFIX) and len(session_id) > len(APP_SESSION_PREFIX)


def guard_violation(method: str, path: str, body: bytes | None,
                    allowed_deliver: tuple[str, ...] = ("local",)) -> tuple[int, str, str] | None:
    """Returns (status, code, message) when a request must be refused, else None.

    Pure function of the request so it can be tested without a server."""
    def parsed() -> dict[str, Any] | None:
        if not body:
            return {}
        try:
            value = json.loads(body)
        except (ValueError, UnicodeDecodeError):
            return None
        return value if isinstance(value, dict) else None

    read_only = (403, "session_read_only", "Only the app's own sessions can be changed; other sessions are read-only.")

    if method == "DELETE" and _SESSION_ITEM.match(path):
        # Hermes' HTTP delete orphans compression continuations and leaves transcript files;
        # deletion goes through the verified cascade at /brainbox/sessions/{id} instead.
        return (403, "use_brainbox_session_delete",
                "Delete chats through DELETE /brainbox/sessions/{id}, which removes the whole conversation and verifies it.")
    if method == "PATCH":
        m = _SESSION_ITEM.match(path)
        if m and not _is_app_session(m.group(1)):
            return read_only
    if method == "POST":
        m = _SESSION_WRITE_ACTION.match(path)
        if m and not _is_app_session(m.group(1)):
            return read_only
        if path == "/api/sessions":
            data = parsed()
            if data is None:
                return (400, "invalid_json", "Request body must be a JSON object.")
            if not _is_app_session(data.get("id") or data.get("session_id")):
                return (403, "session_id_required", "New sessions must use an app session id (ios_…).")
            if data.get("source") not in (None, "api_server"):
                return (403, "session_source_not_allowed", "New sessions must use source api_server.")
        if path == "/v1/runs":
            data = parsed()
            if data is None:
                return (400, "invalid_json", "Request body must be a JSON object.")
            if data.get("session_id") is not None and not _is_app_session(data.get("session_id")):
                return read_only
            if data.get("previous_response_id") is not None:
                return (403, "previous_response_not_allowed", "Response chaining is not available through the Brainbox proxy.")
    if method in ("POST", "PATCH") and _JOB_PATHS.match(path):
        data = parsed()
        if data is None:
            return (400, "invalid_json", "Request body must be a JSON object.")
        if "deliver" in data and data["deliver"] not in allowed_deliver:
            return (403, "delivery_not_allowed",
                    f"Job delivery to {data['deliver']!r} is not enabled on this server (allowed: {', '.join(allowed_deliver)}).")
    return None


# --------------------------------------------------------------------------- config

@dataclass
class Device:
    name: str
    token_sha256: str
    admin: bool = False
    # Direct VPS terminal for this device (also needs [terminal] enabled = true).
    terminal: bool = False

    def matches(self, token: str) -> bool:
        digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
        return hmac.compare_digest(digest, self.token_sha256.lower())

    @property
    def key(self) -> str:
        """Stable, non-secret device identity (prefix of the token hash) used for ownership."""
        return self.token_sha256.lower()[:24]


@dataclass
class ProxyConfig:
    host: str = "127.0.0.1"
    port: int = 8766
    path_prefix: str = "/hermes"
    hermes_url: str = "http://127.0.0.1:8642"
    # The Hermes API_SERVER_KEY is read from ONE of these at startup.
    hermes_key_file: str = ""
    hermes_env_file: str = ""
    audit_log: str = "/var/lib/brainbox-gateway/hermes-proxy-audit.log"
    max_auth_failures_per_minute: int = 10
    max_requests_per_minute: int = 300
    max_body_bytes: int = 4_000_000
    devices: list[Device] = field(default_factory=list)
    # Profile routing / admin.
    hermes_home: str = "/root/.hermes"
    hermes_bin: str = "/opt/hermes-src/venv/bin/hermes"
    multiplex_profiles: bool = False
    profile_admin_enabled: bool = False
    # Where scheduled-job results may be delivered (`deliver` on /api/jobs).
    # "local" keeps results in Hermes; add "telegram" only deliberately.
    allowed_deliver: tuple[str, ...] = ("local",)
    # Proxy-owned state (session ownership registry, file inbox/outbox, push tokens).
    state_dir: str = "/var/lib/brainbox-gateway"
    files: WorkspaceConfig = field(default_factory=WorkspaceConfig)
    terminal: TerminalConfig = field(default_factory=TerminalConfig)
    push: PushConfig = field(default_factory=PushConfig)

    @property
    def state_db(self) -> str:
        return str(Path(self.hermes_home) / "state.db")

    @property
    def sessions_dir(self) -> str:
        return str(Path(self.hermes_home) / "sessions")

    def device_for(self, token: str) -> Device | None:
        if not token:
            return None
        found = None
        for device in self.devices:  # compare against every hash (constant-ish time)
            if device.matches(token):
                found = device
        return found

    @property
    def prefix(self) -> str:
        p = "/" + self.path_prefix.strip("/")
        return "" if p == "/" else p


def load_config(path: str) -> ProxyConfig:
    with open(path, "rb") as fh:
        raw = tomllib.load(fh)
    return config_from_dict(raw)


def config_from_dict(raw: dict[str, Any]) -> ProxyConfig:
    p = raw.get("proxy", {})
    profiles = raw.get("profiles", {})
    jobs = raw.get("jobs", {})
    allowed_deliver = jobs.get("allowed_deliver", ["local"])
    if not isinstance(allowed_deliver, list) or not all(isinstance(d, str) and DELIVER_RE.fullmatch(d) for d in allowed_deliver):
        raise ValueError("jobs.allowed_deliver must be a list of delivery target names, e.g. [\"local\"]")
    devices = [Device(name=str(d["name"]), token_sha256=str(d["token_sha256"]), admin=bool(d.get("admin", False)),
                      terminal=bool(d.get("terminal", False)))
               for d in raw.get("devices", [])]
    state_dir = str(p.get("state_dir", "/var/lib/brainbox-gateway"))
    cfg = ProxyConfig(
        host=str(p.get("host", "127.0.0.1")), port=int(p.get("port", 8766)),
        path_prefix=str(p.get("path_prefix", "/hermes")), hermes_url=str(p.get("hermes_url", "http://127.0.0.1:8642")).rstrip("/"),
        hermes_key_file=str(p.get("hermes_key_file", "")), hermes_env_file=str(p.get("hermes_env_file", "")),
        audit_log=str(p.get("audit_log", "/var/lib/brainbox-gateway/hermes-proxy-audit.log")),
        max_auth_failures_per_minute=int(p.get("max_auth_failures_per_minute", 10)),
        max_requests_per_minute=int(p.get("max_requests_per_minute", 300)),
        max_body_bytes=int(p.get("max_body_bytes", 4_000_000)),
        devices=devices,
        hermes_home=str(profiles.get("hermes_home", "/root/.hermes")),
        hermes_bin=str(profiles.get("hermes_bin", "/opt/hermes-src/venv/bin/hermes")),
        multiplex_profiles=bool(profiles.get("multiplex", False)),
        profile_admin_enabled=bool(profiles.get("admin_enabled", False)),
        allowed_deliver=tuple(allowed_deliver),
        state_dir=state_dir,
        files=WorkspaceConfig.from_dict(raw.get("files", {}), state_dir),
        terminal=TerminalConfig.from_dict(raw.get("terminal", {})),
        push=PushConfig.from_dict(raw.get("push", {})),
    )
    validate(cfg)
    return cfg


def validate(cfg: ProxyConfig) -> None:
    if not cfg.devices:
        raise ValueError("at least one [[devices]] entry with token_sha256 is required")
    for d in cfg.devices:
        if not re.fullmatch(r"[0-9a-fA-F]{64}", d.token_sha256):
            raise ValueError(f"device {d.name!r}: token_sha256 must be a 64-char hex SHA-256")
    if not (cfg.hermes_key_file or cfg.hermes_env_file):
        raise ValueError("set proxy.hermes_key_file or proxy.hermes_env_file (where API_SERVER_KEY lives)")
    upstream = urlsplit(cfg.hermes_url)
    if upstream.scheme not in ("http", "https") or upstream.hostname not in ("127.0.0.1", "::1", "localhost"):
        raise ValueError("proxy.hermes_url must point at the Hermes API Server on loopback "
                         "(e.g. http://127.0.0.1:8642) — the server key must never cross the network")
    if cfg.host not in ("127.0.0.1", "::1", "localhost") and not cfg.host.startswith("100."):
        log.warning("hermes-proxy is binding %s — prefer 127.0.0.1 behind `tailscale serve`", cfg.host)


def read_env_value(path: str, key: str) -> str:
    """Reads KEY=value from a dotenv file without executing it."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return ""
    value = ""
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        name, _, raw = line.partition("=")
        if name.strip() == key:
            raw = raw.strip()
            if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "'\"":
                raw = raw[1:-1]
            value = raw
    return value


def resolve_hermes_key(cfg: ProxyConfig, profile: str | None = None) -> str:
    if profile and profile != "default":
        return read_env_value(str(Path(cfg.hermes_home) / "profiles" / profile / ".env"), "API_SERVER_KEY")
    if cfg.hermes_key_file:
        try:
            return Path(cfg.hermes_key_file).read_text(encoding="utf-8").strip()
        except OSError:
            return ""
    return read_env_value(cfg.hermes_env_file, "API_SERVER_KEY")


# --------------------------------------------------------------------------- limits & audit

class SlidingWindow:
    def __init__(self, limit: int, window: float = 60.0) -> None:
        self.limit = limit
        self.window = window
        self.events: dict[str, deque[float]] = defaultdict(deque)

    def hit(self, key: str, now: float | None = None) -> bool:
        """Records an event; returns False once the limit is exceeded."""
        now = time.monotonic() if now is None else now
        q = self.events[key]
        while q and now - q[0] > self.window:
            q.popleft()
        if len(q) >= self.limit:
            return False
        q.append(now)
        return True

    def blocked(self, key: str, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        q = self.events.get(key)
        if not q:
            return False
        while q and now - q[0] > self.window:
            q.popleft()
        return len(q) >= self.limit


class AuditLog:
    def __init__(self, path: str) -> None:
        self.path = path

    def write(self, **entry: Any) -> None:
        if not self.path:
            return
        entry = {"ts": round(time.time(), 3), **entry}
        try:
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
            with open(self.path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(entry, sort_keys=True) + "\n")
            os.chmod(self.path, 0o600)
        except OSError as exc:  # never fail a request because auditing failed
            log.warning("audit log write failed: %s", exc)


# --------------------------------------------------------------------------- app

def route_allowed(method: str, path: str) -> bool:
    return any(m == method and rx.match(path) for m, rx in ALLOWED_ROUTES)


def split_profile(path: str) -> tuple[str | None, str]:
    """`/p/<name>/rest` → (name, /rest)."""
    if path.startswith("/p/"):
        parts = path.split("/", 3)  # ['', 'p', name, rest]
        name = parts[2] if len(parts) > 2 else ""
        rest = "/" + parts[3] if len(parts) > 3 else "/"
        return name, rest
    return None, path


def json_error(status: int, message: str, code: str) -> web.Response:
    return web.json_response({"error": {"message": message, "type": "brainbox_proxy_error", "code": code}}, status=status)


class HermesProxy:
    def __init__(self, cfg: ProxyConfig, *, hermes_key: str | None = None) -> None:
        self.cfg = cfg
        self.auth_failures = SlidingWindow(cfg.max_auth_failures_per_minute)
        self.requests = SlidingWindow(cfg.max_requests_per_minute)
        self.audit = AuditLog(cfg.audit_log)
        self._hermes_key = hermes_key if hermes_key is not None else resolve_hermes_key(cfg)
        self._client: ClientSession | None = None
        self.owners = OwnershipRegistry(str(Path(cfg.state_dir) / "session-owners.json"))
        self.session_store = ReadOnlySessionStore(cfg.state_db)
        self.workspace = Workspace(cfg.files)
        self.terminals = TerminalManager(cfg.terminal)
        self.push = PushService(cfg.push, cfg.state_dir, self._hermes_get, audit=self.audit.write)
        self.started_at = time.time()
        self.commands = CommandCatalog(cfg.hermes_bin, cfg.hermes_home)

    # -- lifecycle ---------------------------------------------------------

    def app(self) -> web.Application:
        app = web.Application(client_max_size=self.cfg.max_body_bytes, middlewares=[self._security_headers])
        prefix = self.cfg.prefix
        app.router.add_route("GET", f"{prefix}/brainbox/info", self.handle_info)
        app.router.add_route("GET", f"{prefix}/brainbox/profiles", self.handle_list_profiles)
        app.router.add_route("POST", f"{prefix}/brainbox/profiles", self.handle_create_profile)
        app.router.add_route("GET", f"{prefix}/brainbox/sessions", self.handle_list_app_sessions)
        app.router.add_route("DELETE", f"{prefix}/brainbox/sessions/{{session_id}}", self.handle_delete_app_session)
        app.router.add_route("GET", f"{prefix}/brainbox/system", self.handle_system)
        app.router.add_route("GET", f"{prefix}/brainbox/commands", self.handle_commands)
        app.router.add_route("POST", f"{prefix}/brainbox/commands/skill", self.handle_skill_command)
        app.router.add_route("GET", f"{prefix}/brainbox/files", self.handle_files_list)
        app.router.add_route("GET", f"{prefix}/brainbox/files/download", self.handle_files_download)
        app.router.add_route("POST", f"{prefix}/brainbox/files/upload", self.handle_files_upload)
        app.router.add_route("DELETE", f"{prefix}/brainbox/files", self.handle_files_delete)
        app.router.add_route("GET", f"{prefix}/brainbox/terminal/status", self.handle_terminal_status)
        app.router.add_route("GET", f"{prefix}/brainbox/terminal", self.handle_terminal)
        app.router.add_route("GET", f"{prefix}/brainbox/push", self.handle_push_status)
        app.router.add_route("POST", f"{prefix}/brainbox/push/register", self.handle_push_register)
        app.router.add_route("DELETE", f"{prefix}/brainbox/push/register", self.handle_push_unregister)
        app.router.add_route("POST", f"{prefix}/brainbox/push/test", self.handle_push_test)
        app.router.add_route("*", prefix + "/{tail:.*}", self.handle_proxy)
        app.on_startup.append(self._startup)
        app.on_cleanup.append(self._cleanup)
        return app

    async def _startup(self, _app: web.Application) -> None:
        if not self._hermes_key:
            log.error("No API_SERVER_KEY found for Hermes — requests will fail with 503 until it is configured.")
        self._client = ClientSession(timeout=ClientTimeout(total=None, connect=10, sock_read=None), auto_decompress=False)
        if self.cfg.files.enabled:
            try:
                await asyncio.to_thread(self.workspace.ensure)
                await asyncio.to_thread(self.workspace.sweep_temp)
            except OSError as exc:
                log.error("workspace folder %s unavailable: %s", self.cfg.files.root, exc)
        revoked = self.push.registry.prune({d.key for d in self.cfg.devices})
        if revoked:
            log.info("revoked push tokens of %d removed device(s)", revoked)
        if self.cfg.push.enabled:
            problems = self.push.problems()
            if problems:
                log.warning("push notifications enabled but not ready: %s", "; ".join(problems))
            self.push.start()

    async def _cleanup(self, _app: web.Application) -> None:
        self.terminals.shutdown()
        await self.push.stop()
        if self._client:
            await self._client.close()

    @web.middleware
    async def _security_headers(self, request: web.Request, handler):
        response = await handler(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("Cache-Control", "no-store")
        return response

    # -- auth ----------------------------------------------------------------

    def _client_key(self, request: web.Request) -> str:
        # Behind `tailscale serve` the peer is loopback; Tailscale adds the user.
        return request.headers.get("Tailscale-User-Login") or (request.remote or "unknown")

    def _authenticate(self, request: web.Request) -> tuple[Device | None, web.Response | None]:
        key = self._client_key(request)
        if self.auth_failures.blocked(key):
            return None, json_error(429, "Too many failed sign-in attempts. Wait a minute.", "auth_rate_limited")
        header = request.headers.get("Authorization", "")
        token = header[7:].strip() if header.startswith("Bearer ") else ""
        device = self.cfg.device_for(token)
        if device is None:
            self.auth_failures.hit(key)
            log.warning("rejected device token from %s", key)
            return None, json_error(401, "Invalid or missing device token.", "invalid_device_token")
        if not self.requests.hit(device.name):
            return None, json_error(429, "Too many requests from this device.", "rate_limited")
        return device, None

    # -- brainbox endpoints --------------------------------------------------

    async def handle_info(self, request: web.Request) -> web.Response:
        device, err = self._authenticate(request)
        if err:
            return err
        return web.json_response({
            "service": "brainbox-hermes-proxy", "version": __version__,
            "profile_admin": bool(self.cfg.profile_admin_enabled and device.admin),
            "multiplex_profiles": self.cfg.multiplex_profiles, "device_name": device.name,
            "features": self._features(device),
        })

    def _features(self, device: Device) -> dict[str, Any]:
        return {"chat_management": True, "files": self.cfg.files.enabled, "diagnostics": True, "commands": True,
                "terminal": bool(self.cfg.terminal.enabled and device.terminal),
                "push": {"enabled": self.cfg.push.enabled, "ready": self.cfg.push.enabled and self.push.ready}}

    def _profiles(self) -> list[dict[str, Any]]:
        out = [{"name": "default", "description": "The main Hermes profile", "has_api_key": bool(self._hermes_key), "routable": True}]
        root = Path(self.cfg.hermes_home) / "profiles"
        try:
            names = sorted(p.name for p in root.iterdir() if p.is_dir() and PROFILE_RE.fullmatch(p.name))
        except OSError:
            names = []
        for name in names:
            has_key = bool(resolve_hermes_key(self.cfg, name))
            out.append({"name": name, "description": None, "has_api_key": has_key,
                        "routable": bool(self.cfg.multiplex_profiles and has_key)})
        return out

    # -- app chat sessions (list incl. archived, verified delete) -------------

    async def _hermes_get(self, method: str, path: str) -> tuple[int, Any]:
        return await self._hermes_call(method, path)

    async def _hermes_call(self, method: str, path: str, payload: Any = None) -> tuple[int, Any]:
        assert self._client is not None
        headers = {"Authorization": f"Bearer {self._hermes_key}", "Accept": "application/json"}
        try:
            async with self._client.request(method, self.cfg.hermes_url + path, headers=headers, json=payload,
                                            allow_redirects=False) as upstream:
                try:
                    data = await upstream.json(content_type=None)
                except (ValueError, UnicodeDecodeError):
                    data = None
                return upstream.status, data
        except (OSError, asyncio.TimeoutError):
            return 502, None

    async def handle_list_app_sessions(self, request: web.Request) -> web.Response:
        """GET /brainbox/sessions?state=active|archived — this device's ios_ conversations, read
        straight from state.db (read-only) because Hermes' list API can't return archived ones."""
        device, err = self._authenticate(request)
        if err:
            return err
        state = request.query.get("state", "active")
        if state not in ("active", "archived"):
            return json_error(400, "state must be active or archived.", "invalid_state")
        try:
            limit = max(1, min(200, int(request.query.get("limit", "100"))))
            offset = max(0, int(request.query.get("offset", "0")))
        except ValueError:
            return json_error(400, "limit and offset must be integers.", "invalid_pagination")
        try:
            rows = await asyncio.to_thread(self.session_store.list_app_sessions, archived=state == "archived",
                                           limit=limit, offset=offset)
        except SessionStoreUnavailable as exc:
            log.warning("session store unavailable: %s", exc)
            return json_error(503, "Hermes' session database can't be read right now.", "session_store_unavailable")
        has_more = len(rows) > limit
        owners = self.owners.owners()
        visible = []
        for row in rows[:limit]:
            owner = owners.get(row["id"])
            if owner is None or owner == device.key or device.admin:
                visible.append({**row, "owned": owner == device.key})
        return web.json_response({"object": "list", "state": state, "data": visible, "has_more": has_more,
                                  "limit": limit, "offset": offset})

    async def handle_delete_app_session(self, request: web.Request) -> web.Response:
        """DELETE /brainbox/sessions/{id} — permanently delete one of this device's conversations:
        its compression continuations (deepest first) and the root via Hermes' DELETE API, then
        the leftover transcript/debug files, then verify none of it remains."""
        device, err = self._authenticate(request)
        if err:
            return err
        session_id = request.match_info["session_id"]
        audit = lambda outcome, **extra: self.audit.write(device=device.name, action="session.delete",  # noqa: E731
                                                          path=f"/brainbox/sessions/{session_id[:64]}", outcome=outcome, **extra)
        if not is_app_session(session_id):
            audit("invalid_session_id")
            return json_error(400, "Only the app's own conversations (ios_…) can be deleted.", "invalid_session_id")
        if not self.owners.may_manage(session_id, device.key, device.admin):
            audit("session_not_owned")
            return json_error(403, "This conversation belongs to another device.", "session_not_owned")
        if not self._hermes_key:
            return json_error(503, "Hermes API key is not configured on the server.", "hermes_key_missing")
        try:
            exists = await asyncio.to_thread(self.session_store.exists, session_id)
            chain = await asyncio.to_thread(self.session_store.continuation_chain, session_id) if exists else []
        except SessionStoreUnavailable as exc:
            log.warning("session store unavailable: %s", exc)
            return json_error(503, "Hermes' session database can't be read right now, so nothing was deleted.",
                              "session_store_unavailable")
        if not exists:
            status, _ = await self._hermes_call("GET", f"/api/sessions/{session_id}")
            if status == 404:
                self.owners.forget(session_id)
                audit("already_absent")
                return json_error(404, "This conversation no longer exists on Hermes.", "session_not_found")
            audit("unverifiable")
            return json_error(503, "Hermes reports this conversation but its database copy couldn't be checked; nothing was deleted.",
                              "session_store_unavailable")

        targets = [*chain, session_id]  # continuations deepest first, root last
        deleted: list[str] = []
        for target in targets:
            status, data = await self._hermes_call("DELETE", f"/api/sessions/{target}")
            if status == 404:
                deleted.append(target)
                continue
            if status >= 300 or not (isinstance(data, dict) and data.get("deleted")):
                audit("delete_failed", status=status, deleted=len(deleted))
                return web.json_response({"error": {"message": "Hermes did not delete the whole conversation. Nothing was reported as deleted; try again.",
                                                    "type": "brainbox_proxy_error", "code": "delete_failed"},
                                          "deleted_sessions": deleted, "remaining_sessions": targets[len(deleted):]},
                                         status=502)
            deleted.append(target)

        files: list[str] = []
        for target in deleted:
            files += await asyncio.to_thread(remove_session_files, self.cfg.sessions_dir, target)
        try:
            still_there = [t for t in targets if await asyncio.to_thread(self.session_store.exists, t)]
            messages_left = await asyncio.to_thread(self.session_store.message_count, targets)
        except SessionStoreUnavailable:
            still_there, messages_left = [], -1
        if still_there or messages_left != 0:
            audit("unverified", remaining=len(still_there))
            return web.json_response({"error": {"message": "Hermes accepted the deletion but it could not be verified.",
                                                "type": "brainbox_proxy_error", "code": "delete_unverified"},
                                      "deleted_sessions": deleted, "remaining_sessions": still_there}, status=500)
        self.owners.forget(session_id)
        audit("ok", sessions=len(deleted), files=len(files))
        return web.json_response({"object": "brainbox.session.deleted", "id": session_id, "deleted_sessions": deleted,
                                  "files_removed": len(files), "verified": True})

    # -- server overview (read-only) ------------------------------------------------

    async def handle_system(self, request: web.Request) -> web.Response:
        device, err = self._authenticate(request)
        if err:
            return err
        host = await asyncio.to_thread(host_snapshot, ["/", self.cfg.files.root if self.cfg.files.enabled else "",
                                                       self.cfg.hermes_home])
        started = time.monotonic()
        status, body = await self._hermes_call("GET", "/health")
        latency = round((time.monotonic() - started) * 1000, 1)
        hermes = {"reachable": status == 200, "http_status": status if status != 502 else None,
                  "latency_ms": latency if status == 200 else None,
                  "status": body.get("status") if isinstance(body, dict) and isinstance(body.get("status"), str) else None,
                  "key_configured": bool(self._hermes_key)}
        return web.json_response({
            "object": "brainbox.system", "host": host, "hermes": hermes,
            "proxy": {"version": __version__, "uptime_seconds": round(time.time() - self.started_at, 1),
                      "features": self._features(device)},
        })

    # -- slash commands -------------------------------------------------------------------

    async def handle_commands(self, request: web.Request) -> web.Response:
        """GET /brainbox/commands — Hermes' command registry and skill commands (read-only)."""
        device, err = self._authenticate(request)
        if err:
            return err
        try:
            catalog = await self.commands.catalog()
        except CommandsUnavailable as exc:
            return json_error(503, exc.message, exc.code)
        return web.json_response({"object": "brainbox.commands", "api_runs_commands": False, **catalog})

    async def handle_skill_command(self, request: web.Request) -> web.Response:
        """POST /brainbox/commands/skill {name, instruction} — the message Hermes builds for
        ``/<skill> <instruction>``. The app sends it as the run input."""
        device, err = self._authenticate(request)
        if err:
            return err
        try:
            body = await request.json()
        except (ValueError, UnicodeDecodeError):
            return json_error(400, "Body must be JSON.", "invalid_json")
        if not isinstance(body, dict):
            return json_error(400, "Body must be a JSON object.", "invalid_json")
        name = str(body.get("name", "")).lstrip("/")
        instruction = body.get("instruction") or ""
        if not isinstance(instruction, str):
            return json_error(400, "instruction must be text.", "invalid_instruction")
        try:
            message = await self.commands.skill_message(name, instruction)
        except ValueError as exc:
            return json_error(400, "Invalid skill name or instruction.", str(exc))
        except CommandsUnavailable as exc:
            return json_error(503, exc.message, exc.code)
        if message is None:
            return json_error(404, f"Hermes has no skill command /{name}.", "skill_not_found")
        self.audit.write(device=device.name, action="command.skill", skill=name)
        return web.json_response({"object": "brainbox.skill_invocation", "name": name, "message": message})

    # -- workspace files ----------------------------------------------------------------

    def _files_guard(self, request: web.Request) -> tuple[Device | None, web.Response | None]:
        device, err = self._authenticate(request)
        if err:
            return None, err
        if not self.cfg.files.enabled:
            return None, json_error(404, "File transfer is turned off on the server.", "files_disabled")
        return device, None

    @staticmethod
    def _workspace_error(exc: WorkspaceError) -> web.Response:
        return json_error(exc.status, exc.message, exc.code)

    async def handle_files_list(self, request: web.Request) -> web.Response:
        device, err = self._files_guard(request)
        if err:
            return err
        path = request.query.get("path", "")
        try:
            entries = await asyncio.to_thread(self.workspace.list, path, owner_dir(device.key))
        except WorkspaceError as exc:
            return self._workspace_error(exc)
        return web.json_response({"object": "list", "path": path.strip("/"), "data": entries,
                                  "max_upload_bytes": self.cfg.files.max_upload_bytes,
                                  "allowed_extensions": list(self.cfg.files.allowed_extensions)})

    async def handle_files_download(self, request: web.Request) -> web.StreamResponse:
        device, err = self._files_guard(request)
        if err:
            return err
        rel = request.query.get("path", "")
        owner = owner_dir(device.key)
        try:
            if request.query.get("id"):
                rel = await asyncio.to_thread(self.workspace.find, request.query["id"], owner)
            path, size = await asyncio.to_thread(self.workspace.file_for_download, rel, owner)
        except WorkspaceError as exc:
            return self._workspace_error(exc)
        self.audit.write(device=device.name, action="files.download", path=rel, size=size)
        quoted = quote(path.name, safe="")
        return web.FileResponse(path, headers={
            "Content-Disposition": f"attachment; filename*=UTF-8''{quoted}",
            "Content-Type": "application/octet-stream"})

    async def handle_files_upload(self, request: web.Request) -> web.Response:
        device, err = self._files_guard(request)
        if err:
            return err
        area = request.query.get("area", "inbox")
        name = request.query.get("name", "")
        declared = request.content_length
        try:
            directory, clean = await asyncio.to_thread(self.workspace.check_upload, area, name, declared, owner_dir(device.key))
            tmp, fd = await asyncio.to_thread(self.workspace.temp_upload, directory)
        except WorkspaceError as exc:
            return self._workspace_error(exc)
        limit = self.cfg.files.max_upload_bytes
        written = 0
        ok = False
        try:
            with os.fdopen(fd, "wb") as fh:
                async for chunk in request.content.iter_chunked(64 * 1024):
                    written += len(chunk)
                    if written > limit:
                        return json_error(413, f"Files can be at most {limit // 1_000_000} MB.", "too_large")
                    fh.write(chunk)
            if written == 0:
                return json_error(400, "The file is empty.", "empty_file")
            if declared is not None and written != declared:
                return json_error(400, "The upload was incomplete.", "incomplete_upload")
            entry = await asyncio.to_thread(self.workspace.finish_upload, tmp, directory, clean)
            ok = True
        except WorkspaceError as exc:
            return self._workspace_error(exc)
        finally:
            if not ok:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
        self.audit.write(device=device.name, action="files.upload", path=entry["path"], size=written)
        # The absolute server path lets the app point the agent at the attachment.
        return web.json_response({"object": "brainbox.file", "file": entry,
                                  "absolute_path": str(self.workspace.root / entry["path"])}, status=201)

    async def handle_files_delete(self, request: web.Request) -> web.Response:
        device, err = self._files_guard(request)
        if err:
            return err
        rel = request.query.get("path", "")
        owner = owner_dir(device.key)
        try:
            if request.query.get("id"):
                rel = await asyncio.to_thread(self.workspace.find, request.query["id"], owner)
            await asyncio.to_thread(self.workspace.delete, rel, owner)
        except WorkspaceError as exc:
            return self._workspace_error(exc)
        self.audit.write(device=device.name, action="files.delete", path=rel)
        return web.json_response({"object": "brainbox.file.deleted", "path": rel})

    # -- direct terminal ----------------------------------------------------------------------

    def _terminal_problem(self, device: Device) -> tuple[int, str, str] | None:
        if not self.cfg.terminal.enabled:
            return 404, "The terminal is turned off on the server ([terminal] enabled = false).", "terminal_disabled"
        if not device.terminal:
            return 403, "This device isn't allowed to open a terminal (set terminal = true for it).", "terminal_not_allowed"
        return None

    async def handle_terminal_status(self, request: web.Request) -> web.Response:
        device, err = self._authenticate(request)
        if err:
            return err
        problem = self._terminal_problem(device)
        info: dict[str, Any] = {"available": problem is None, "reason": problem[1] if problem else None,
                                "code": problem[2] if problem else None}
        if problem is None:
            info.update(user=self.cfg.terminal.user, sessions=[
                {"id": s.id, "created": round(s.created), "attached": s.listener is not None, "cols": s.cols, "rows": s.rows}
                for s in self.terminals.sessions.values() if s.owner == device.key and s.alive])
        return web.json_response(info)

    async def handle_terminal(self, request: web.Request) -> web.StreamResponse:
        device, err = self._authenticate(request)
        if err:
            return err
        problem = self._terminal_problem(device)
        if problem:
            self.audit.write(device=device.name, action="terminal.open", outcome=problem[2])
            return json_error(*problem)
        try:
            cols = max(10, min(500, int(request.query.get("cols", "80"))))
            rows = max(4, min(300, int(request.query.get("rows", "24"))))
        except ValueError:
            return json_error(400, "cols and rows must be numbers.", "invalid_size")
        wanted = request.query.get("session")
        session = None
        if wanted:
            session = self.terminals.get(wanted, device.key)
            if session is None:
                return json_error(404, "That terminal session has ended.", "session_ended")
        else:
            try:
                session = self.terminals.open(device.key, cols, rows)
            except TerminalUnavailable as exc:
                self.audit.write(device=device.name, action="terminal.open", outcome=exc.code)
                return json_error(503 if exc.code != "too_many_sessions" else 429, exc.message, exc.code)
            except OSError as exc:
                log.error("terminal spawn failed: %s", exc)
                return json_error(503, "The server couldn't start a shell.", "terminal_spawn_failed")
        ws = web.WebSocketResponse(heartbeat=25, max_msg_size=256 * 1024)
        await ws.prepare(request)
        queue: asyncio.Queue = asyncio.Queue(maxsize=1024)

        def listener(frame: dict[str, Any]) -> None:
            try:
                queue.put_nowait(frame)
            except asyncio.QueueFull:
                pass

        reattached = wanted is not None
        if session.listener is not None:   # another connection had it: take over
            session.listener({"type": "error", "code": "taken_over", "message": "Opened on another connection."})
        session.listener = listener
        session.detached_at = None
        if reattached:
            session.resize(cols, rows)
        self.audit.write(device=device.name, action="terminal.reattach" if reattached else "terminal.open", outcome="ok")
        await ws.send_json({"type": "ready", "session": session.id, "user": session.user, "reattached": reattached,
                            "cols": session.cols, "rows": session.rows})
        if reattached and session.scrollback:
            await ws.send_json({"type": "output", "data": session.replay()})

        async def pump() -> None:
            while True:
                frame = await queue.get()
                await ws.send_json(frame)
                if frame.get("type") in ("exit",) or frame.get("code") == "taken_over":
                    await ws.close()
                    return

        sender = asyncio.create_task(pump())
        closed_by_client = False
        try:
            async for msg in ws:
                if msg.type != web.WSMsgType.TEXT:
                    continue
                frame = parse_client_frame(msg.data)
                if frame is None:
                    await ws.send_json({"type": "error", "code": "bad_frame", "message": "Unrecognised message."})
                    continue
                kind = frame["type"]
                if kind == "input":
                    session.write(frame["data"])
                elif kind == "resize":
                    session.resize(frame["cols"], frame["rows"])
                elif kind == "interrupt":
                    session.interrupt()
                elif kind == "close":
                    closed_by_client = True
                    break
        finally:
            sender.cancel()
            if session.listener is listener:
                session.listener = None
                session.detached_at = time.monotonic()
            if closed_by_client:
                self.terminals.close(session.id)
            self.audit.write(device=device.name, action="terminal.close" if closed_by_client else "terminal.detach")
            if not ws.closed:
                await ws.close()
        return ws

    # -- push notifications -------------------------------------------------------------------------

    async def handle_push_status(self, request: web.Request) -> web.Response:
        device, err = self._authenticate(request)
        if err:
            return err
        return web.json_response(self.push.status(device.key))

    async def handle_push_register(self, request: web.Request) -> web.Response:
        device, err = self._authenticate(request)
        if err:
            return err
        try:
            body = await request.json()
        except (ValueError, UnicodeDecodeError):
            return json_error(400, "Body must be JSON.", "invalid_json")
        if not isinstance(body, dict):
            return json_error(400, "Body must be a JSON object.", "invalid_json")
        prefs = body.get("preferences")
        if prefs is not None and not (isinstance(prefs, dict) and all(k in EVENT_KINDS and isinstance(v, bool) for k, v in prefs.items())):
            return json_error(400, "Unknown notification preference.", "invalid_preferences")
        try:
            result = self.push.registry.register(device.key, str(body.get("token", "")),
                                                 str(body.get("environment", "production")), prefs)
        except ValueError as exc:
            return json_error(400, "Invalid APNs device token or environment.", str(exc))
        self.audit.write(device=device.name, action="push.register", environment=result["environment"])
        return web.json_response({"object": "brainbox.push.registration", **result, "status": self.push.status(device.key)})

    async def handle_push_unregister(self, request: web.Request) -> web.Response:
        device, err = self._authenticate(request)
        if err:
            return err
        token = request.query.get("token")
        removed = self.push.registry.unregister(device.key, token if token else None)
        self.audit.write(device=device.name, action="push.unregister", removed=removed)
        return web.json_response({"object": "brainbox.push.unregistered", "removed": removed})

    async def handle_push_test(self, request: web.Request) -> web.Response:
        device, err = self._authenticate(request)
        if err:
            return err
        problems = self.push.problems()
        if problems:
            return json_error(503, problems[0], "push_not_ready")
        if not self.push.registry.for_device(device.key):
            return json_error(409, "This device hasn't registered for notifications yet.", "push_not_registered")
        sent = await self.push.notify(Notification("test", "Brainbox test", "Notifications are working.",
                                                   "brainbox://settings", f"test:{device.key}:{time.time_ns()}", device.key))
        return web.json_response({"object": "brainbox.push.test", "sent": sent})

    async def handle_list_profiles(self, request: web.Request) -> web.Response:
        _, err = self._authenticate(request)
        if err:
            return err
        return web.json_response({"profiles": self._profiles()})

    async def handle_create_profile(self, request: web.Request) -> web.Response:
        device, err = self._authenticate(request)
        if err:
            return err
        if not (self.cfg.profile_admin_enabled and device.admin):
            self.audit.write(device=device.name, action="profile.create", outcome="forbidden")
            return json_error(403, "Profile creation is disabled for this device.", "profile_admin_disabled")
        try:
            body = await request.json()
        except Exception:
            return json_error(400, "Body must be JSON.", "invalid_json")
        name = str(body.get("name", ""))
        description = body.get("description")
        clone = bool(body.get("clone", True))
        if not PROFILE_RE.fullmatch(name) or name == "default":
            return json_error(400, "Invalid profile name.", "invalid_profile_name")
        if description is not None:
            description = str(description)
            if len(description) > 200 or any(ord(ch) < 32 for ch in description):
                return json_error(400, "Description must be one line, at most 200 characters.", "invalid_description")
        if (Path(self.cfg.hermes_home) / "profiles" / name).exists():
            return json_error(409, "That profile already exists.", "profile_exists")
        argv = [self.cfg.hermes_bin, "profile", "create", name]
        if clone:
            argv.append("--clone")
        if description:
            argv += ["--description", description]
        env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": str(Path(self.cfg.hermes_home).parent),
               "HERMES_HOME": self.cfg.hermes_home, "LANG": "C.UTF-8"}
        try:
            proc = await asyncio.create_subprocess_exec(*argv, stdin=asyncio.subprocess.DEVNULL,
                                                        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, env=env)
            try:
                _, stderr = await asyncio.wait_for(proc.communicate(), timeout=60)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
                self.audit.write(device=device.name, action="profile.create", profile=name, outcome="timeout")
                return json_error(504, "Profile creation timed out.", "profile_create_timeout")
        except OSError as exc:
            self.audit.write(device=device.name, action="profile.create", profile=name, outcome="spawn_failed")
            log.error("could not run hermes profile create: %s", exc)
            return json_error(500, "Could not run the Hermes CLI on the server.", "profile_create_failed")
        if proc.returncode != 0:
            self.audit.write(device=device.name, action="profile.create", profile=name, outcome=f"exit_{proc.returncode}")
            log.error("hermes profile create failed (%s): %s", proc.returncode, (stderr or b"")[-500:].decode(errors="replace"))
            return json_error(500, "Hermes could not create the profile. Check the server log.", "profile_create_failed")
        self.audit.write(device=device.name, action="profile.create", profile=name, clone=clone, outcome="ok")
        info = next((p for p in self._profiles() if p["name"] == name),
                    {"name": name, "description": description, "has_api_key": False, "routable": False})
        info["description"] = description
        return web.json_response({"profile": info}, status=201)

    # -- proxy -----------------------------------------------------------------

    async def handle_proxy(self, request: web.Request) -> web.StreamResponse:
        tail = "/" + request.match_info.get("tail", "")
        profile, path = split_profile(tail)
        method = request.method.upper()
        public = profile is None and (method, path) in PUBLIC_ROUTES
        device: Device | None = None
        if not public:
            device, err = self._authenticate(request)
            if err:
                return err
        if not route_allowed(method, path):
            return json_error(404, "This route is not available through the Brainbox proxy.", "route_not_allowed")
        if profile is not None:
            if not PROFILE_RE.fullmatch(profile):
                return json_error(400, "Invalid profile name.", "invalid_profile_name")
            if not self.cfg.multiplex_profiles and profile != "default":
                return json_error(404, "Profile routing is not enabled on this server.", "profiles_not_enabled")
        body = await request.read() if request.can_read_body else None
        violation = guard_violation(method, path, body, self.cfg.allowed_deliver)
        if violation is not None:
            status, code, message = violation
            self.audit.write(device=device.name if device else None, action="guard", method=method, path=tail, outcome=code)
            return json_error(status, message, code)
        write_target = session_write_target(method, path, body)
        if write_target and is_app_session(write_target) and device is not None \
                and not self.owners.may_manage(write_target, device.key, device.admin):
            self.audit.write(device=device.name, action="guard", method=method, path=tail, outcome="session_not_owned")
            return json_error(403, "This conversation belongs to another device.", "session_not_owned")
        key = resolve_hermes_key(self.cfg, profile) if profile and profile != "default" else self._hermes_key
        if not key:
            return json_error(503, "Hermes API key is not configured on the server.", "hermes_key_missing")

        upstream_path = path if not profile or profile == "default" else f"/p/{profile}{path}"
        url = self.cfg.hermes_url + upstream_path
        headers = {h: request.headers[h] for h in FORWARD_REQUEST_HEADERS if h in request.headers}
        headers["Authorization"] = f"Bearer {key}"

        assert self._client is not None
        try:
            upstream = await self._client.request(method, url, params=request.query, data=body, headers=headers,
                                                  allow_redirects=False)
        except (OSError, asyncio.TimeoutError) as exc:
            log.warning("upstream error for %s %s: %s", method, path, exc)
            return json_error(502, "Hermes is not reachable on the server.", "hermes_unreachable")

        mutating = method in ("POST", "PATCH", "DELETE")
        if write_target and is_app_session(write_target) and device is not None and (
                upstream.status < 300 or (path == "/api/sessions" and upstream.status == 409)):
            # First successful write records (or claims, for pre-registry sessions) the owner.
            self.owners.record(write_target, device.key)
        try:
            content_type = upstream.headers.get("Content-Type", "")
            if content_type.startswith("text/event-stream"):
                response = web.StreamResponse(status=upstream.status)
                for h in FORWARD_RESPONSE_HEADERS:
                    if h in upstream.headers:
                        response.headers[h] = upstream.headers[h]
                response.headers["X-Accel-Buffering"] = "no"
                await response.prepare(request)
                try:
                    async for chunk in upstream.content.iter_any():
                        await response.write(chunk)
                except (ConnectionResetError, asyncio.CancelledError):
                    raise
                except Exception as exc:  # upstream dropped mid-stream
                    log.info("stream for %s ended: %s", path, exc)
                if mutating:
                    self.audit.write(device=device.name if device else None, method=method, path=tail, status=upstream.status)
                return response
            data = await upstream.read()
            if (device is not None and method == "POST" and path == "/v1/runs" and upstream.status < 300
                    and (profile is None or profile == "default") and self.cfg.push.enabled):
                try:
                    self.push.watch_run(json.loads(data).get("run_id"), device.key)
                except (ValueError, AttributeError):
                    pass
            response = web.Response(status=upstream.status, body=data)
            for h in FORWARD_RESPONSE_HEADERS:
                if h in upstream.headers:
                    response.headers[h] = upstream.headers[h]
            if mutating:
                self.audit.write(device=device.name if device else None, method=method, path=tail, status=upstream.status)
            return response
        finally:
            upstream.release()


def serve(cfg: ProxyConfig) -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    proxy = HermesProxy(cfg)
    log.info("hermes-proxy listening on http://%s:%d%s → %s", cfg.host, cfg.port, cfg.prefix, cfg.hermes_url)
    web.run_app(proxy.app(), host=cfg.host, port=cfg.port, access_log=None, print=None)


def insecure_permissions(path: str) -> bool:
    """True if a config/key file is readable or writable by group/others."""
    try:
        return bool(os.stat(path).st_mode & 0o077)
    except OSError:
        return False
