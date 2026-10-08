"""Gateway configuration (TOML). Secrets never live in this file: the
access token is stored only as a SHA-256 hash, and Hermes keeps its own
API keys in its own config."""
from __future__ import annotations

import hashlib
import hmac
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path

if sys.version_info >= (3, 11):
    import tomllib
else:  # pragma: no cover
    import tomli as tomllib


@dataclass
class FileRoot:
    path: str
    read_only: bool = False


@dataclass
class HermesConfig:
    # "library" (official AIAgent API in an isolated worker) or "cli".
    mode: str = "library"
    source_dir: str = "/opt/hermes-src"
    python: str = "/opt/hermes-src/venv/bin/python"
    hermes_bin: str = "/opt/hermes-src/venv/bin/hermes"
    hermes_home: str = "/root/.hermes"
    # Toolsets passed to Hermes (empty = Hermes defaults).
    toolsets: list[str] = field(default_factory=list)
    # Never auto-approve dangerous commands unless explicitly enabled.
    allow_dangerous_commands: bool = False
    # Let app chats read/write Hermes' persistent memory.
    use_memory: bool = True
    request_timeout_seconds: int = 900
    max_iterations: int = 60
    # Set to true only after tools/probe_hermes.py confirmed the setup.
    verified: bool = False


@dataclass
class GatewayConfig:
    host: str = "127.0.0.1"
    port: int = 8765
    path: str = "/v1/agent"
    token_sha256: str = ""
    adapter: str = "echo"  # "echo" | "hermes"
    agent_name: str = "Echo"
    heartbeat_seconds: int = 20
    data_dir: str = "/var/lib/brainbox-gateway"
    max_auth_failures_per_minute: int = 10
    hermes: HermesConfig = field(default_factory=HermesConfig)
    file_roots: list[FileRoot] = field(default_factory=list)
    services: list[str] = field(default_factory=list)
    log_units: list[str] = field(default_factory=list)
    terminal_enabled: bool = False
    terminal_shell: str = "/bin/bash"
    terminal_cwd: str = "/root"

    # ---- auth -------------------------------------------------------------

    def token_matches(self, token: str) -> bool:
        if not self.token_sha256 or not token:
            return False
        digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
        return hmac.compare_digest(digest, self.token_sha256.lower())

    @property
    def capabilities(self) -> list[str]:
        caps = ["streaming", "cancellation", "conversationHistory", "serverMetrics", "logs"]
        if self.services:
            caps.append("serviceControl")
        if self.file_roots:
            caps.append("fileSystem")
        if self.terminal_enabled:
            caps.append("terminal")
        return caps


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def load(path: str | os.PathLike) -> GatewayConfig:
    raw = tomllib.loads(Path(path).read_text())
    return from_dict(raw)


def from_dict(raw: dict) -> GatewayConfig:
    server = raw.get("server", {})
    auth = raw.get("auth", {})
    agent = raw.get("agent", {})
    hermes_raw = raw.get("hermes", {})
    system = raw.get("system", {})
    terminal = raw.get("terminal", {})

    cfg = GatewayConfig(
        host=server.get("host", "127.0.0.1"),
        port=int(server.get("port", 8765)),
        path=server.get("path", "/v1/agent"),
        heartbeat_seconds=int(server.get("heartbeat_seconds", 20)),
        data_dir=server.get("data_dir", "/var/lib/brainbox-gateway"),
        token_sha256=auth.get("token_sha256", ""),
        max_auth_failures_per_minute=int(auth.get("max_failures_per_minute", 10)),
        adapter=agent.get("adapter", "echo"),
        agent_name=agent.get("name", "Echo"),
        hermes=HermesConfig(**{k: v for k, v in hermes_raw.items() if k in HermesConfig.__dataclass_fields__}),
        file_roots=[FileRoot(path=r["path"], read_only=bool(r.get("read_only", False))) for r in system.get("file_roots", [])],
        services=list(system.get("services", [])),
        log_units=list(system.get("log_units", [])),
        terminal_enabled=bool(terminal.get("enabled", False)),
        terminal_shell=terminal.get("shell", "/bin/bash"),
        terminal_cwd=terminal.get("cwd", "/root"),
    )
    validate(cfg)
    return cfg


def validate(cfg: GatewayConfig) -> None:
    if len(cfg.token_sha256) != 64:
        raise ValueError("auth.token_sha256 must be a 64-char SHA-256 hex digest (run: brainbox-gateway hash-token)")
    if cfg.adapter not in ("echo", "hermes"):
        raise ValueError("agent.adapter must be 'echo' or 'hermes'")
    if cfg.hermes.mode not in ("library", "cli"):
        raise ValueError("hermes.mode must be 'library' or 'cli'")
    if cfg.host not in ("127.0.0.1", "::1", "localhost") and not cfg.host.startswith("100."):
        # 100.64.0.0/10 is Tailscale. Anything else must be a deliberate choice.
        if not os.environ.get("BRAINBOX_ALLOW_PUBLIC_BIND"):
            raise ValueError(
                f"Refusing to bind {cfg.host}: use 127.0.0.1 behind `tailscale serve`, a Tailscale 100.x address, "
                "or set BRAINBOX_ALLOW_PUBLIC_BIND=1 if you really mean it."
            )
    for root in cfg.file_roots:
        if not root.path.startswith("/") or root.path == "/":
            raise ValueError(f"file root must be an absolute directory other than '/': {root.path}")
