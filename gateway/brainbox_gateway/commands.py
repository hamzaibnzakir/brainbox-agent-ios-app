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

Plus three things the API server lacks but Telegram has, run with Hermes' own functions:

* registry-owned executors (``hermes_cli.slash_exec``: /help, /commands, /version, /profile …);
* /btw (``agent.side_question.answer_side_question`` on a read-only transcript snapshot);
* the gateway prompt Telegram adds every turn (``GatewayRunner._load_ephemeral_system_prompt``:
  ``display.personality`` / ``agent.system_prompt``) and a read-only Telegram-vs-API parity report.

All of it comes from a short-lived helper process running in Hermes' own virtualenv. The helper
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
op = req.get("op")
out = {}
if op == "catalog":
    from hermes_cli.commands import COMMAND_REGISTRY
    out["native"] = [{"name": c.name, "description": c.description, "category": c.category,
                      "aliases": list(c.aliases), "args_hint": c.args_hint,
                      "subcommands": list(getattr(c, "subcommands", ()) or ()),
                      "cli_only": bool(c.cli_only), "gateway_only": bool(c.gateway_only),
                      "busy_policy": getattr(c, "busy_policy", "reject"),
                      "executor": bool(getattr(c, "execute", None))}
                     for c in COMMAND_REGISTRY]
    from agent.skill_commands import get_skill_commands
    out["skills"] = [{"name": key.lstrip("/"), "skill": info.get("name", ""),
                      "description": (info.get("description") or "")[:300]}
                     for key, info in sorted(get_skill_commands().items())]
elif op == "skill":
    from agent.skill_commands import build_skill_invocation_message, resolve_skill_command_key
    key = resolve_skill_command_key(req["name"])
    out["message"] = build_skill_invocation_message(key, req.get("instruction") or "") if key else None
    out["key"] = key
elif op == "exec":
    # Registry-owned executors: the exact text Telegram's /help, /commands, /version... produce.
    from hermes_cli.slash_exec import CommandContext, execute_command
    try:
        reply = execute_command(req["name"], CommandContext(surface="gateway", args=req.get("args") or "",
                                                            options={"page_size": 20}))
        out = {"text": reply.text, "format": reply.format}
    except LookupError:
        out = {"error": "no_executor"}
elif op == "btw":
    # Telegram's /btw: one-shot side question on a transcript snapshot; history untouched.
    from hermes_state import SessionDB
    history = SessionDB(read_only=True).get_messages_as_conversation(req["session_id"])
    if not history:
        out = {"error": "no_history"}
    else:
        from gateway.run import _resolve_runtime_agent_kwargs, _resolve_gateway_model
        rt = _resolve_runtime_agent_kwargs()
        model = rt.pop("model", None) or _resolve_gateway_model()
        main_runtime = {"model": model, **{k: rt.get(k) for k in ("provider", "base_url", "api_key", "api_mode")}}
        from agent.side_question import answer_side_question
        out = {"answer": answer_side_question(req["question"], history, parent_agent=None, main_runtime=main_runtime)}
elif op == "persona":
    # What Telegram adds as its ephemeral system prompt every turn (personality / agent.system_prompt).
    from gateway.run import GatewayRunner
    out = {"prompt": GatewayRunner._load_ephemeral_system_prompt() or ""}
elif op == "parity":
    # Each fact is read independently so one renamed internal can't hide the rest.
    from gateway.run import GatewayRunner
    def fact(fn, default=None):
        try:
            return fn()
        except Exception as exc:
            out.setdefault("unavailable", []).append(f"{getattr(fn, '__name__', 'fact')}: {type(exc).__name__}")
            return default
    def toolsets():
        from gateway.run import _load_gateway_config
        from hermes_cli.tools_config import _get_platform_tools
        cfg = _load_gateway_config() or {}
        tg = set(_get_platform_tools(cfg, "telegram"))
        api = set(_get_platform_tools(cfg, "api_server"))
        explicit = cfg.get("platform_toolsets") or {}
        return {"telegram": sorted(tg), "api_server": sorted(api),
                "only_telegram": sorted(tg - api), "only_api_server": sorted(api - tg),
                "explicit_telegram": isinstance(explicit.get("telegram"), list),
                "explicit_api_server": isinstance(explicit.get("api_server"), list)}
    def model():
        from gateway.run import _resolve_gateway_model
        return _resolve_gateway_model() or ""
    def persona_chars():
        return len(GatewayRunner._load_ephemeral_system_prompt() or "")
    def provider_routing():
        return bool(GatewayRunner._load_provider_routing())
    def prefill():
        return len(GatewayRunner._load_prefill_messages() or [])
    def fallback():
        return len(GatewayRunner._load_fallback_model() or [])
    def busy_input_mode():
        # What Telegram does with a message sent while the agent works: interrupt | queue | steer.
        return GatewayRunner._load_busy_input_mode()
    def version():
        from hermes_cli import __version__  # Hermes' canonical version (dist-info can be stale)
        return __version__
    out.update({"toolsets": fact(toolsets, {"telegram": [], "api_server": [], "only_telegram": [], "only_api_server": [],
                                            "explicit_telegram": False, "explicit_api_server": False}),
                "model": fact(model, ""), "persona_prompt_chars": fact(persona_chars, 0),
                "provider_routing": fact(provider_routing, False), "prefill_messages": fact(prefill, 0),
                "fallback_chain": fact(fallback, 0), "busy_input_mode": fact(busy_input_mode, "interrupt"),
                "hermes_version": fact(version, "")})
print(json.dumps(out))
"""


class CommandsUnavailable(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class CommandCatalog:
    def __init__(self, hermes_bin: str, hermes_home: str, *, timeout: float = 25, ttl: float = 60,
                 persona_ttl: float = 60) -> None:
        self.python = str(Path(hermes_bin).parent / "python")
        # /opt/hermes-src/venv/bin/hermes → /opt/hermes-src (the Hermes checkout)
        self.source_dir = str(Path(hermes_bin).resolve().parent.parent.parent) if hermes_bin else "/"
        self.hermes_home = hermes_home
        self.timeout = timeout
        self.ttl = ttl
        self._cache: tuple[float, dict[str, Any]] | None = None
        self._persona: tuple[float, str] | None = None
        self.persona_ttl = persona_ttl

    def _env(self) -> dict[str, str]:
        return {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "HOME": os.environ.get("HOME", "/root"), "HERMES_HOME": self.hermes_home,
                "HERMES_PLATFORM": "api_server", "PYTHONDONTWRITEBYTECODE": "1", "LANG": "C.UTF-8"}

    async def _run(self, request: dict[str, Any], timeout: float | None = None) -> dict[str, Any]:
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
            stdout, stderr = await asyncio.wait_for(proc.communicate(json.dumps(request).encode()), timeout or self.timeout)
        except asyncio.TimeoutError:
            proc.kill()
            raise CommandsUnavailable("hermes_helper_timeout", "Hermes took too long to answer.")
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

    async def execute(self, name: str, args: str) -> dict[str, Any]:
        if not SKILL_NAME_RE.fullmatch(name or ""):
            raise ValueError("invalid_command")
        if len(args) > MAX_INSTRUCTION:
            raise ValueError("arguments_too_long")
        return await self._run({"op": "exec", "name": name, "args": args})

    async def side_question(self, session_id: str, question: str) -> dict[str, Any]:
        if not question.strip():
            raise ValueError("question_required")
        if len(question) > MAX_INSTRUCTION:
            raise ValueError("question_too_long")
        return await self._run({"op": "btw", "session_id": session_id, "question": question}, timeout=210)

    async def persona_prompt(self) -> str:
        """Telegram's per-turn ephemeral prompt, cached briefly (Hermes re-reads it every turn)."""
        cached = self._persona
        if cached and time.monotonic() - cached[0] < self.persona_ttl:
            return cached[1]
        data = await self._run({"op": "persona"})
        prompt = data.get("prompt") if isinstance(data.get("prompt"), str) else ""
        self._persona = (time.monotonic(), prompt)
        return prompt

    async def parity(self) -> dict[str, Any]:
        return await self._run({"op": "parity"})

    async def skill_message(self, name: str, instruction: str) -> str | None:
        if not SKILL_NAME_RE.fullmatch(name or ""):
            raise ValueError("invalid_skill")
        if len(instruction) > MAX_INSTRUCTION:
            raise ValueError("instruction_too_long")
        data = await self._run({"op": "skill", "name": name, "instruction": instruction})
        message = data.get("message")
        return message if isinstance(message, str) and message.strip() else None
