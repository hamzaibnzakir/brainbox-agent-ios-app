"""Slash-command catalog and skill invocation, using Hermes' own code.

Hermes' API server never interprets slash commands: ``/v1/runs`` hands ``input`` to the
model as text (verified in hermes-agent 284d220). Commands are parsed only by its CLI, TUI
and messaging gateway. So the app routes commands itself and needs two facts from Hermes:

* the command registry (``hermes_cli.commands.COMMAND_REGISTRY``) — names, descriptions,
  argument hints — so the app recognises Hermes commands it can't run over the API and
  says so instead of sending them to the model;
* the installed skill commands, and for ``/<skill> …`` the exact message Hermes would
  build (``agent.skill_commands.build_skill_invocation_message``), so a skill command from
  the app behaves like one typed in Telegram.

Both come from a short-lived helper process running in Hermes' own virtualenv. The helper
code is a constant; user input (skill name, instruction) travels on stdin as JSON, never in
argv or a shell. Nothing here writes anything.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
from pathlib import Path
from typing import Any

log = logging.getLogger("brainbox.commands")

SKILL_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
MAX_INSTRUCTION = 8000

HELPER = r"""
import json, sys
req = json.load(sys.stdin)
out = {}
if req.get("op") == "catalog":
    from hermes_cli.commands import COMMAND_REGISTRY
    out["native"] = [{"name": c.name, "description": c.description, "category": c.category,
                      "aliases": list(c.aliases), "args_hint": c.args_hint,
                      "cli_only": bool(c.cli_only), "gateway_only": bool(c.gateway_only)}
                     for c in COMMAND_REGISTRY]
    from agent.skill_commands import get_skill_commands
    out["skills"] = [{"name": key.lstrip("/"), "skill": info.get("name", ""),
                      "description": (info.get("description") or "")[:300]}
                     for key, info in sorted(get_skill_commands().items())]
elif req.get("op") == "skill":
    from agent.skill_commands import build_skill_invocation_message, resolve_skill_command_key
    key = resolve_skill_command_key(req["name"])
    out["message"] = build_skill_invocation_message(key, req.get("instruction") or "") if key else None
    out["key"] = key
print(json.dumps(out))
"""


class CommandsUnavailable(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class CommandCatalog:
    def __init__(self, hermes_bin: str, hermes_home: str, *, timeout: float = 25, ttl: float = 60) -> None:
        self.python = str(Path(hermes_bin).parent / "python")
        # /opt/hermes-src/venv/bin/hermes → /opt/hermes-src (the Hermes checkout)
        self.source_dir = str(Path(hermes_bin).resolve().parent.parent.parent) if hermes_bin else "/"
        self.hermes_home = hermes_home
        self.timeout = timeout
        self.ttl = ttl
        self._cache: tuple[float, dict[str, Any]] | None = None

    def _env(self) -> dict[str, str]:
        return {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "HOME": os.environ.get("HOME", "/root"), "HERMES_HOME": self.hermes_home,
                "HERMES_PLATFORM": "api_server", "PYTHONDONTWRITEBYTECODE": "1", "LANG": "C.UTF-8"}

    async def _run(self, request: dict[str, Any]) -> dict[str, Any]:
        if not os.path.isfile(self.python):
            raise CommandsUnavailable("hermes_python_missing", "Hermes' Python wasn't found next to profiles.hermes_bin.")
        try:
            proc = await asyncio.create_subprocess_exec(
                self.python, "-c", HELPER, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, cwd=self.source_dir if os.path.isdir(self.source_dir) else "/",
                env=self._env())
        except OSError as exc:
            raise CommandsUnavailable("hermes_helper_failed", "Couldn't run Hermes' command helper.") from exc
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(json.dumps(request).encode()), self.timeout)
        except asyncio.TimeoutError:
            proc.kill()
            raise CommandsUnavailable("hermes_helper_timeout", "Hermes took too long to list its commands.")
        if proc.returncode != 0:
            log.warning("command helper exited %s: %s", proc.returncode, (stderr or b"")[-400:].decode(errors="replace"))
            raise CommandsUnavailable("hermes_helper_failed", "Hermes' command helper failed. Check the proxy log.")
        try:
            lines = [line for line in stdout.decode("utf-8", "replace").splitlines() if line.strip()]
            return json.loads(lines[-1])
        except (ValueError, IndexError) as exc:
            raise CommandsUnavailable("hermes_helper_failed", "Hermes' command helper returned nothing usable.") from exc

    async def catalog(self) -> dict[str, Any]:
        if self._cache and time.monotonic() - self._cache[0] < self.ttl:
            return self._cache[1]
        data = await self._run({"op": "catalog"})
        native = [c for c in data.get("native", []) if isinstance(c, dict) and isinstance(c.get("name"), str)]
        skills = [s for s in data.get("skills", []) if isinstance(s, dict) and SKILL_NAME_RE.fullmatch(str(s.get("name", "")))]
        result = {"native": native, "skills": skills}
        self._cache = (time.monotonic(), result)
        return result

    async def skill_message(self, name: str, instruction: str) -> str | None:
        if not SKILL_NAME_RE.fullmatch(name or ""):
            raise ValueError("invalid_skill")
        if len(instruction) > MAX_INSTRUCTION:
            raise ValueError("instruction_too_long")
        data = await self._run({"op": "skill", "name": name, "instruction": instruction})
        message = data.get("message")
        return message if isinstance(message, str) and message.strip() else None
