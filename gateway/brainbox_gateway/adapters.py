"""Agent adapters: translate one Brainbox chat turn into a backend call.

Every adapter receives a RunContext and reports progress through
`ctx.emit(kind, payload)` where kind is one of:
    status  {"state": ..., "tool"?: ...}
    delta   {"text": str}
    tool.started / tool.output / tool.finished   (Brainbox payload shapes)
    title   {"title": str}
It returns the updated conversation history (list of messages) to persist.
Cancellation = the asyncio task is cancelled; adapters must clean up
subprocesses they started (and nothing else — never the Hermes service).
"""
from __future__ import annotations

import asyncio
import json
import os
import signal
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Awaitable, Callable

from .config import GatewayConfig
from .protocol import ProtocolError

Emit = Callable[[str, dict], Awaitable[None]]


@dataclass
class RunContext:
    conversation_id: str
    content: str
    history: list
    emit: Emit


class AgentAdapter:
    agent_id = "agent"
    agent_name = "Agent"
    version: str | None = None

    async def run(self, ctx: RunContext) -> list:  # pragma: no cover - interface
        raise NotImplementedError


# ---------------------------------------------------------------------------
# Echo: a real end-to-end path for testing the app <-> gateway link without
# touching Hermes. Clearly named so it can never be mistaken for Hermes.
# ---------------------------------------------------------------------------

class EchoAdapter(AgentAdapter):
    agent_id = "echo"
    agent_name = "Echo (gateway test)"
    version = "1"

    def __init__(self, delay: float = 0.03):
        self.delay = delay

    async def run(self, ctx: RunContext) -> list:
        await ctx.emit("status", {"state": "thinking"})
        await asyncio.sleep(self.delay)
        if "tool" in ctx.content.lower():
            tid = "echo_" + uuid.uuid4().hex[:8]
            await ctx.emit("status", {"state": "tool", "tool": "Terminal"})
            await ctx.emit("tool.started", {"toolCallId": tid, "kind": "terminal", "name": "echo.tool", "title": "Echo tool", "input": "echo hello"})
            await ctx.emit("tool.output", {"toolCallId": tid, "chunk": "hello\n"})
            await ctx.emit("tool.finished", {"toolCallId": tid, "status": "succeeded", "output": "hello", "exitCode": 0})
        await ctx.emit("status", {"state": "streaming"})
        reply = f"Gateway echo — you said: **{ctx.content}**\n\nThe Brainbox gateway is reachable and authenticated."
        for word in reply.split(" "):
            await ctx.emit("delta", {"text": word + " "})
            await asyncio.sleep(self.delay)
        return ctx.history + [{"role": "user", "content": ctx.content}, {"role": "assistant", "content": reply}]


# ---------------------------------------------------------------------------
# Hermes
# ---------------------------------------------------------------------------

WORKER_PATH = Path(__file__).with_name("hermes_worker.py")


async def _terminate(proc: asyncio.subprocess.Process) -> None:
    """Stop one request's process group: SIGTERM, then SIGKILL. Never touches
    hermes-gateway.service (the Telegram bot keeps running)."""
    if proc.returncode is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        await asyncio.wait_for(proc.wait(), timeout=4)
    except asyncio.TimeoutError:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        await proc.wait()


def _guess_kind(name: str) -> str:
    n = name.lower()
    for key, kind in (("terminal", "terminal"), ("shell", "terminal"), ("bash", "terminal"), ("file", "file"), ("read", "file"),
                      ("write", "file"), ("search", "search"), ("web", "browser"), ("browser", "browser"), ("git", "git"),
                      ("code", "code"), ("python", "code"), ("http", "network"), ("mcp", "other")):
        if key in n:
            return kind
    return "other"


class HermesLibraryAdapter(AgentAdapter):
    """Runs Hermes through its documented Python API (`run_agent.AIAgent`)
    inside an isolated worker process using Hermes' own venv. One process per
    turn: cancellation kills only that process group."""

    agent_id = "hermes"
    agent_name = "Hermes"

    def __init__(self, cfg: GatewayConfig):
        self.cfg = cfg
        self.h = cfg.hermes

    def _env(self) -> dict:
        env = {k: v for k, v in os.environ.items() if k in ("PATH", "LANG", "LC_ALL", "HOME", "USER", "LOGNAME", "TZ")}
        env["HERMES_HOME"] = self.h.hermes_home
        env["PYTHONPATH"] = self.h.source_dir
        env["PYTHONUNBUFFERED"] = "1"
        return env

    async def run(self, ctx: RunContext) -> list:
        if not self.h.verified:
            raise ProtocolError("not_implemented", "Hermes adapter not verified yet — run tools/probe_hermes.py on the VPS, then set hermes.verified = true.")
        request = {
            "message": ctx.content,
            "history": ctx.history,
            "toolsets": self.h.toolsets,
            "use_memory": self.h.use_memory,
            "max_iterations": self.h.max_iterations,
            "source_dir": self.h.source_dir,
        }
        await ctx.emit("status", {"state": "thinking"})
        proc = await asyncio.create_subprocess_exec(
            self.h.python, str(WORKER_PATH),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            cwd=self.h.source_dir, env=self._env(), start_new_session=True,
            limit=8 * 1024 * 1024,
        )
        stderr_tail: list[str] = []

        async def drain_stderr():
            assert proc.stderr
            async for line in proc.stderr:
                text = line.decode("utf-8", "replace").rstrip()
                if text:
                    stderr_tail.append(text)
                    del stderr_tail[:-40]
                    print(f"[hermes-worker] {text}", file=sys.stderr)

        stderr_task = asyncio.create_task(drain_stderr())
        try:
            assert proc.stdin and proc.stdout
            proc.stdin.write(json.dumps(request, ensure_ascii=False, default=str).encode())
            proc.stdin.close()  # no stdin => Hermes can't block on interactive approval prompts

            result: dict | None = None
            streamed = False
            open_tools: dict[str, str] = {}

            async def read_events():
                nonlocal result, streamed
                async for raw in proc.stdout:
                    try:
                        ev = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    kind = ev.get("event")
                    if kind == "delta" and ev.get("text"):
                        if not streamed:
                            await ctx.emit("status", {"state": "streaming"})
                        streamed = True
                        await ctx.emit("delta", {"text": ev["text"]})
                    elif kind == "tool":
                        name = str(ev.get("name") or "tool")
                        tid = open_tools.get(name) or ("hermes_" + uuid.uuid4().hex[:10])
                        if name not in open_tools:
                            open_tools[name] = tid
                            await ctx.emit("status", {"state": "tool", "tool": name})
                            await ctx.emit("tool.started", {"toolCallId": tid, "kind": _guess_kind(name), "name": name,
                                                            "title": str(ev.get("title") or name), "input": str(ev.get("input") or "")[:2000]})
                        if ev.get("output"):
                            await ctx.emit("tool.output", {"toolCallId": tid, "chunk": str(ev["output"])[:8000]})
                        if ev.get("done"):
                            await ctx.emit("tool.finished", {"toolCallId": tid, "status": "failed" if ev.get("error") else "succeeded",
                                                             "output": str(ev.get("output") or "")[:8000], "isError": bool(ev.get("error"))})
                            open_tools.pop(name, None)
                    elif kind == "result":
                        result = ev
                    elif kind == "error":
                        raise ProtocolError("agent_unavailable", str(ev.get("message") or "Hermes failed"))

            await asyncio.wait_for(read_events(), timeout=self.h.request_timeout_seconds)
            await proc.wait()
            for name, tid in open_tools.items():
                await ctx.emit("tool.finished", {"toolCallId": tid, "status": "succeeded", "output": ""})
            if result is None:
                detail = stderr_tail[-1] if stderr_tail else f"exit code {proc.returncode}"
                raise ProtocolError("agent_unavailable", f"Hermes worker ended without a result ({detail[:300]})")
            final = str(result.get("final") or "")
            if not streamed and final:
                # No streaming callback in this Hermes build: release the final
                # text in small chunks so the app still renders progressively.
                await ctx.emit("status", {"state": "streaming"})
                for i in range(0, len(final), 48):
                    await ctx.emit("delta", {"text": final[i:i + 48]})
                    await asyncio.sleep(0.01)
            messages = result.get("messages")
            if isinstance(messages, list) and messages:
                return messages
            return ctx.history + [{"role": "user", "content": ctx.content}, {"role": "assistant", "content": final}]
        except asyncio.TimeoutError:
            raise ProtocolError("timeout", "Hermes took too long to answer", retryable=True)
        finally:
            await _terminate(proc)
            stderr_task.cancel()


class HermesCLIAdapter(AgentAdapter):
    """Fallback: one-shot `hermes chat -q ... -Q`. No tool events (Hermes
    doesn't print structured events); earlier turns are given as context in
    the prompt because CLI session resumption is not verified."""

    agent_id = "hermes"
    agent_name = "Hermes (CLI)"

    def __init__(self, cfg: GatewayConfig):
        self.cfg = cfg
        self.h = cfg.hermes

    def build_command(self, prompt: str) -> list[str]:
        cmd = [self.h.hermes_bin, "chat", "-q", prompt, "-Q"]
        if self.h.toolsets:
            cmd += ["-t", ",".join(self.h.toolsets)]
        if self.h.allow_dangerous_commands:
            cmd.insert(1, "--yolo")
        return cmd

    @staticmethod
    def build_prompt(history: list, content: str, max_chars: int = 12_000) -> str:
        turns = []
        for m in history[-12:]:
            role, text = m.get("role"), m.get("content")
            if role in ("user", "assistant") and isinstance(text, str) and text.strip():
                turns.append(f"{role.upper()}: {text.strip()}")
        context = "\n\n".join(turns)[-max_chars:]
        if not context:
            return content
        return f"Earlier in this Brainbox conversation:\n\n{context}\n\nUSER: {content}"

    async def run(self, ctx: RunContext) -> list:
        if not self.h.verified:
            raise ProtocolError("not_implemented", "Hermes adapter not verified yet — run tools/probe_hermes.py on the VPS, then set hermes.verified = true.")
        await ctx.emit("status", {"state": "thinking"})
        env = {k: v for k, v in os.environ.items() if k in ("PATH", "LANG", "LC_ALL", "HOME", "USER", "LOGNAME", "TZ")}
        env["HERMES_HOME"] = self.h.hermes_home
        proc = await asyncio.create_subprocess_exec(
            *self.build_command(self.build_prompt(ctx.history, ctx.content)),
            stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            env=env, start_new_session=True,
        )
        chunks: list[str] = []
        try:
            async def pump():
                assert proc.stdout
                first = True
                while True:
                    data = await proc.stdout.read(512)
                    if not data:
                        break
                    text = data.decode("utf-8", "replace")
                    if first:
                        await ctx.emit("status", {"state": "streaming"})
                        first = False
                    chunks.append(text)
                    await ctx.emit("delta", {"text": text})
            await asyncio.wait_for(pump(), timeout=self.h.request_timeout_seconds)
            code = await proc.wait()
            if code != 0:
                err = (await proc.stderr.read()).decode("utf-8", "replace").strip() if proc.stderr else ""
                raise ProtocolError("agent_unavailable", f"hermes exited with {code}: {err[-300:]}")
        except asyncio.TimeoutError:
            raise ProtocolError("timeout", "Hermes took too long to answer", retryable=True)
        finally:
            await _terminate(proc)
        reply = "".join(chunks).strip()
        return ctx.history + [{"role": "user", "content": ctx.content}, {"role": "assistant", "content": reply}]


def build_adapter(cfg: GatewayConfig) -> AgentAdapter:
    if cfg.adapter == "echo":
        return EchoAdapter()
    if cfg.hermes.mode == "cli":
        return HermesCLIAdapter(cfg)
    return HermesLibraryAdapter(cfg)
