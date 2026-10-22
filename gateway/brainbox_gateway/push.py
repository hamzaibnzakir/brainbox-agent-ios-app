"""Apple Push Notifications for Brainbox (off and unconfigured by default).

What it needs (none of it lives in the app or the repository):
* a paid Apple Developer Program membership — free "Personal Team" provisioning can't
  use APNs at all;
* an APNs auth key (.p8) kept on the server only (``[push] key_file``, mode 600), plus
  its Key ID and your Team ID;
* the app's bundle id and the matching APNs environment (development for Xcode/debug
  installs, production for TestFlight/App Store/ad-hoc).

Devices register their APNs token through the proxy (``POST /brainbox/push/register``);
tokens are stored per Brainbox device key and are dropped when that device is removed
from the config, when the device unregisters, or when Apple reports them invalid.

Events (each one only if the device's preferences allow it):
* ``job_done`` / ``job_failed`` — a scheduled job's latest execution finished;
* ``long_task`` — a run started from the app finished after ``long_task_seconds``;
* ``approval`` — a run started from the app is waiting for an approval;
* ``connection`` — Hermes stopped answering the proxy (sent once until it recovers).

Payloads are deliberately generic: a title, a short neutral body and a ``brainbox://``
deep link with ids only. No prompts, outputs, commands, file names or job names.
Every event has a dedupe key; a key is never sent twice.
"""
from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import re
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable

log = logging.getLogger("brainbox.push")

TOKEN_RE = re.compile(r"^[0-9a-fA-F]{64,200}$")
EVENT_KINDS = ("job_done", "job_failed", "long_task", "approval", "connection")
DEFAULT_PREFS = {kind: True for kind in EVENT_KINDS}
BUNDLE_RE = re.compile(r"^[A-Za-z0-9.-]{3,155}$")


@dataclass
class PushConfig:
    enabled: bool = False
    team_id: str = ""
    key_id: str = ""
    key_file: str = ""
    bundle_id: str = ""
    environment: str = "production"
    poll_seconds: int = 60
    long_task_seconds: int = 120

    @staticmethod
    def from_dict(raw: dict[str, Any]) -> "PushConfig":
        cfg = PushConfig(enabled=bool(raw.get("enabled", False)), team_id=str(raw.get("team_id", "")),
                         key_id=str(raw.get("key_id", "")), key_file=str(raw.get("key_file", "")),
                         bundle_id=str(raw.get("bundle_id", "")), environment=str(raw.get("environment", "production")),
                         poll_seconds=int(raw.get("poll_seconds", 60)), long_task_seconds=int(raw.get("long_task_seconds", 120)))
        if cfg.environment not in ("development", "production"):
            raise ValueError("push.environment must be \"development\" or \"production\"")
        if not (15 <= cfg.poll_seconds <= 3600 and 10 <= cfg.long_task_seconds <= 86400):
            raise ValueError("push timing out of range")
        return cfg

    def problems(self) -> list[str]:
        """Why push can't send (empty = ready). Never includes key material."""
        if not self.enabled:
            return ["Push notifications are turned off on the server ([push] enabled = false)."]
        out = []
        if not re.fullmatch(r"[A-Z0-9]{10}", self.team_id):
            out.append("push.team_id is missing (your 10-character Apple Team ID).")
        if not re.fullmatch(r"[A-Z0-9]{10}", self.key_id):
            out.append("push.key_id is missing (the APNs auth key's 10-character Key ID).")
        if not BUNDLE_RE.fullmatch(self.bundle_id):
            out.append("push.bundle_id is missing (the app's bundle identifier).")
        if not self.key_file or not os.path.isfile(self.key_file):
            out.append("push.key_file doesn't point at the APNs .p8 key on the server.")
        try:
            import httpx  # noqa: F401
            import h2  # noqa: F401
        except ImportError:
            out.append("The server needs the optional packages: pip install 'httpx[http2]' cryptography.")
        return out


# --------------------------------------------------------------------------- storage

class JsonState:
    def __init__(self, path: Path, default: Any) -> None:
        self.path = path
        self.default = default

    def load(self) -> Any:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            return data if isinstance(data, type(self.default)) else json.loads(json.dumps(self.default))
        except (OSError, ValueError):
            return json.loads(json.dumps(self.default))

    def save(self, data: Any) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".push-", dir=str(self.path.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(data, fh, sort_keys=True)
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise


class TokenRegistry:
    """{device_key: {token: {"environment": e, "prefs": {...}, "since": ts}}} (mode 600)."""

    def __init__(self, path: Path) -> None:
        self.state = JsonState(path, {})

    def register(self, device_key: str, token: str, environment: str, prefs: dict[str, bool] | None) -> dict[str, Any]:
        if not TOKEN_RE.fullmatch(token or ""):
            raise ValueError("invalid_token")
        if environment not in ("development", "production"):
            raise ValueError("invalid_environment")
        clean = dict(DEFAULT_PREFS)
        for kind, value in (prefs or {}).items():
            if kind in clean and isinstance(value, bool):
                clean[kind] = value
        data = self.state.load()
        # A token belongs to one device: re-registering moves it.
        for tokens in data.values():
            tokens.pop(token.lower(), None)
        data.setdefault(device_key, {})[token.lower()] = {"environment": environment, "prefs": clean, "since": round(time.time())}
        self.state.save(data)
        return {"environment": environment, "prefs": clean}

    def unregister(self, device_key: str, token: str | None = None) -> int:
        data = self.state.load()
        tokens = data.get(device_key, {})
        if token is None:
            removed = len(tokens)
            data.pop(device_key, None)
        else:
            removed = 1 if tokens.pop(token.lower(), None) else 0
            if not tokens:
                data.pop(device_key, None)
        self.state.save(data)
        return removed

    def drop_token(self, token: str) -> None:
        data = self.state.load()
        for key in list(data):
            data[key].pop(token.lower(), None)
            if not data[key]:
                data.pop(key)
        self.state.save(data)

    def prune(self, valid_device_keys: set[str]) -> int:
        """Revokes tokens of devices no longer in the config."""
        data = self.state.load()
        stale = [k for k in data if k not in valid_device_keys]
        for k in stale:
            data.pop(k)
        if stale:
            self.state.save(data)
        return len(stale)

    def for_device(self, device_key: str) -> dict[str, Any]:
        return self.state.load().get(device_key, {})

    def targets(self, kind: str, device_key: str | None = None) -> list[tuple[str, str, str]]:
        """(device_key, token, environment) that want ``kind``."""
        out = []
        for key, tokens in self.state.load().items():
            if device_key is not None and key != device_key:
                continue
            for token, info in tokens.items():
                if info.get("prefs", {}).get(kind, True):
                    out.append((key, token, info.get("environment", "production")))
        return out


class Dedupe:
    def __init__(self, path: Path, keep: int = 1000) -> None:
        self.state = JsonState(path, [])
        self.keep = keep

    def first_time(self, key: str) -> bool:
        seen = self.state.load()
        if key in seen:
            return False
        seen.append(key)
        self.state.save(seen[-self.keep:])
        return True


# --------------------------------------------------------------------------- APNs

def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def provider_jwt(team_id: str, key_id: str, key_pem: bytes, now: float | None = None) -> str:
    """ES256 provider token (RFC 7519) for APNs token-based auth."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

    key = serialization.load_pem_private_key(key_pem, password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey):
        raise ValueError("APNs keys are EC P-256 keys")
    header = _b64(json.dumps({"alg": "ES256", "kid": key_id}, separators=(",", ":")).encode())
    claims = _b64(json.dumps({"iss": team_id, "iat": int(now or time.time())}, separators=(",", ":")).encode())
    signing_input = f"{header}.{claims}".encode()
    r, s = decode_dss_signature(key.sign(signing_input, ec.ECDSA(hashes.SHA256())))
    return f"{header}.{claims}.{_b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


@dataclass
class Notification:
    kind: str
    title: str
    body: str
    link: str
    dedupe_key: str
    device_key: str | None = None   # None = every registered device

    def payload(self) -> dict[str, Any]:
        return {"aps": {"alert": {"title": self.title, "body": self.body}, "sound": "default", "thread-id": self.kind},
                "bb": {"kind": self.kind, "link": self.link}}


SendFn = Callable[[str, str, Notification], Awaitable[int]]  # (token, environment, n) -> HTTP status


class APNsSender:
    def __init__(self, cfg: PushConfig) -> None:
        self.cfg = cfg
        self._jwt: tuple[str, float] | None = None
        self._client = None

    def _token(self) -> str:
        if self._jwt is None or time.time() - self._jwt[1] > 50 * 60:
            pem = Path(self.cfg.key_file).read_bytes()
            self._jwt = (provider_jwt(self.cfg.team_id, self.cfg.key_id, pem), time.time())
        return self._jwt[0]

    async def send(self, token: str, environment: str, n: Notification) -> int:
        import httpx

        if self._client is None:
            self._client = httpx.AsyncClient(http2=True, timeout=15)
        host = "api.sandbox.push.apple.com" if environment == "development" else "api.push.apple.com"
        response = await self._client.post(
            f"https://{host}/3/device/{token}", json=n.payload(),
            headers={"authorization": f"bearer {self._token()}", "apns-topic": self.cfg.bundle_id,
                     "apns-push-type": "alert", "apns-priority": "10",
                     "apns-collapse-id": n.dedupe_key[:64], "apns-expiration": str(int(time.time()) + 3600)})
        if response.status_code == 403 and b"ExpiredProviderToken" in response.content:
            self._jwt = None
        return response.status_code

    async def close(self) -> None:
        if self._client is not None:
            await self._client.aclose()


# --------------------------------------------------------------------------- service

class PushService:
    """Token registry + event watchers. ``hermes_call(method, path) -> (status, json)``."""

    def __init__(self, cfg: PushConfig, state_dir: str, hermes_call: Callable[[str, str], Awaitable[tuple[int, Any]]],
                 send: SendFn | None = None, audit: Callable[..., None] | None = None) -> None:
        self.cfg = cfg
        self.registry = TokenRegistry(Path(state_dir) / "push-tokens.json")
        self.dedupe = Dedupe(Path(state_dir) / "push-sent.json")
        self.hermes_call = hermes_call
        self._sender = APNsSender(cfg) if send is None else None
        self._send = send or self._sender.send  # type: ignore[union-attr]
        self.audit = audit or (lambda **_: None)
        self.jobs_seen: dict[str, tuple[str, str]] | None = None   # job id -> (execution id, status)
        self.runs: dict[str, dict[str, Any]] = {}                    # run id -> {owner, started, notified}
        self.health_failures = 0
        self.connection_down = False
        self._task: asyncio.Task | None = None

    @property
    def ready(self) -> bool:
        return not self.cfg.problems()

    def status(self, device_key: str) -> dict[str, Any]:
        problems = self.cfg.problems()
        registered = self.registry.for_device(device_key)
        return {"enabled": self.cfg.enabled, "ready": not problems, "problems": problems,
                "environment": self.cfg.environment if self.cfg.enabled else None,
                "registered_tokens": len(registered),
                "prefs": next(iter(registered.values()), {}).get("prefs", DEFAULT_PREFS),
                "events": list(EVENT_KINDS)}

    # -- event delivery ----------------------------------------------------------------

    async def notify(self, n: Notification) -> int:
        if not self.ready or not self.dedupe.first_time(n.dedupe_key):
            return 0
        sent = 0
        for device_key, token, environment in self.registry.targets(n.kind, n.device_key):
            try:
                status = await self._send(token, environment, n)
            except Exception as exc:  # network trouble: try again on the next event
                log.warning("APNs send failed: %s", type(exc).__name__)
                continue
            if status == 200:
                sent += 1
            elif status in (400, 410):  # BadDeviceToken / Unregistered
                self.registry.drop_token(token)
            self.audit(action="push.send", kind=n.kind, status=status, device_key=device_key[:8])
        return sent

    # -- watchers --------------------------------------------------------------------------

    def watch_run(self, run_id: str, owner: str) -> None:
        if self.cfg.enabled and isinstance(run_id, str) and re.fullmatch(r"[A-Za-z0-9_.:\-]{1,128}", run_id):
            self.runs[run_id] = {"owner": owner, "started": time.time(), "approval_sent": False}
            while len(self.runs) > 200:
                self.runs.pop(next(iter(self.runs)))

    async def poll_jobs(self) -> None:
        status, body = await self.hermes_call("GET", "/api/jobs?include_disabled=true")
        if status != 200 or not isinstance(body, dict):
            return
        current: dict[str, tuple[str, str]] = {}
        for job in body.get("jobs", []) if isinstance(body.get("jobs"), list) else []:
            if not isinstance(job, dict) or not isinstance(job.get("id"), str):
                continue
            execution = job.get("latest_execution") if isinstance(job.get("latest_execution"), dict) else {}
            current[job["id"]] = (str(execution.get("id") or ""), str(execution.get("status") or ""))
        previous, self.jobs_seen = self.jobs_seen, current
        if previous is None:
            return  # first look: remember, don't announce history
        for job_id, (exec_id, state) in current.items():
            if (exec_id, state) == previous.get(job_id) or not exec_id:
                continue
            if state == "completed":
                await self.notify(Notification("job_done", "Scheduled task finished", "Tap to see the result.",
                                               f"brainbox://tasks/job/{job_id}", f"job:{job_id}:{exec_id}:completed"))
            elif state in ("failed", "error", "timed_out", "interrupted"):
                await self.notify(Notification("job_failed", "Scheduled task failed", "Tap to see what happened.",
                                               f"brainbox://tasks/job/{job_id}", f"job:{job_id}:{exec_id}:failed"))

    async def poll_runs(self) -> None:
        for run_id, info in list(self.runs.items()):
            status, body = await self.hermes_call("GET", f"/v1/runs/{run_id}")
            if status == 404:
                self.runs.pop(run_id, None)
                continue
            if status != 200 or not isinstance(body, dict):
                continue
            state = body.get("status")
            owner = info["owner"]
            if state == "waiting_for_approval" and not info["approval_sent"]:
                info["approval_sent"] = True
                await self.notify(Notification("approval", "Approval needed", "A task is waiting for your decision.",
                                               f"brainbox://tasks/run/{run_id}", f"run:{run_id}:approval:{body.get('updated_at')}", owner))
            elif state in ("completed", "failed", "cancelled", "interrupted"):
                self.runs.pop(run_id, None)
                if time.time() - info["started"] >= self.cfg.long_task_seconds and state != "cancelled":
                    ok = state == "completed"
                    await self.notify(Notification("long_task", "Task finished" if ok else "Task didn't finish",
                                                   "Tap to open it." if ok else "Tap to see what happened.",
                                                   f"brainbox://tasks/run/{run_id}", f"run:{run_id}:{state}", owner))
            elif state != "waiting_for_approval":
                info["approval_sent"] = False

    async def poll_health(self) -> None:
        status, _ = await self.hermes_call("GET", "/health")
        if status == 200:
            self.health_failures = 0
            self.connection_down = False
            return
        self.health_failures += 1
        if self.health_failures >= 3 and not self.connection_down:
            self.connection_down = True
            await self.notify(Notification("connection", "Hermes isn't responding",
                                           "Brainbox can't reach the agent on your server.", "brainbox://server",
                                           f"health:down:{int(time.time() // 3600)}"))

    async def tick(self) -> None:
        for step in (self.poll_health, self.poll_jobs, self.poll_runs):
            try:
                await step()
            except Exception as exc:  # a watcher must never take the proxy down
                log.warning("push watcher %s failed: %s", step.__name__, type(exc).__name__)

    async def run(self) -> None:
        while True:
            await self.tick()
            await asyncio.sleep(min(self.cfg.poll_seconds, 15) if self.runs else self.cfg.poll_seconds)

    def start(self) -> None:
        if self.ready and self._task is None:
            self._task = asyncio.get_running_loop().create_task(self.run())

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
        if self._sender is not None:
            await self._sender.close()
