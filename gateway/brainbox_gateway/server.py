"""WebSocket server implementing Brainbox Agent Protocol v1."""
from __future__ import annotations

import asyncio
import collections
import json
import sys
import time
import uuid
from typing import Any

from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

from . import __version__
from .adapters import AgentAdapter, RunContext, build_adapter
from .config import GatewayConfig
from .conversations import ConversationStore
from .files import FileSandbox
from .protocol import ProtocolError, error_frame, frame, parse, valid_uuid
from .system import Logs, MetricsSampler, Services, processes, server_info
from .terminal import TerminalManager

MAX_CONTENT_CHARS = 32_000
AUTH_TIMEOUT = 10


def log(*parts: Any) -> None:
    print("[brainbox-gateway]", *parts, file=sys.stderr, flush=True)


class Gateway:
    def __init__(self, cfg: GatewayConfig, adapter: AgentAdapter | None = None):
        self.cfg = cfg
        self.adapter = adapter or build_adapter(cfg)
        self.store = ConversationStore(cfg.data_dir)
        self.files = FileSandbox(cfg.file_roots)
        self.services = Services(cfg.services)
        self.logs = Logs(cfg.log_units)
        self.terminal = TerminalManager(cfg.terminal_enabled, cfg.terminal_shell, cfg.terminal_cwd)
        self.sampler = MetricsSampler()
        self.busy_conversations: set[str] = set()
        self.auth_failures: dict[str, collections.deque] = collections.defaultdict(collections.deque)

    # ------------------------------------------------------------------ serve

    async def serve(self) -> None:
        async with serve(self.handle, self.cfg.host, self.cfg.port, max_size=8 * 1024 * 1024,
                         ping_interval=None, server_header=None) as server:
            log(f"listening on ws://{self.cfg.host}:{self.cfg.port}{self.cfg.path} · adapter={self.adapter.agent_name}")
            await server.serve_forever()

    def _rate_limited(self, ip: str) -> bool:
        window = self.auth_failures[ip]
        now = time.monotonic()
        while window and now - window[0] > 60:
            window.popleft()
        return len(window) >= self.cfg.max_auth_failures_per_minute

    async def handle(self, ws: ServerConnection) -> None:
        if ws.request is None or ws.request.path.split("?")[0] != self.cfg.path:
            await ws.close(1008, "unknown path")
            return
        ip = (ws.remote_address or ("?",))[0]
        if self._rate_limited(ip):
            await ws.close(1008, "too many failed attempts")
            return
        session = Session(self, ws)
        try:
            if not await session.authenticate(ip):
                return
            await session.loop()
        except ConnectionClosed:
            pass
        finally:
            await session.shutdown()


class Session:
    def __init__(self, gw: Gateway, ws: ServerConnection):
        self.gw = gw
        self.ws = ws
        self.id = "sess_" + uuid.uuid4().hex
        self.tasks: dict[str, asyncio.Task] = {}
        self.send_lock = asyncio.Lock()

    async def send(self, text: str) -> None:
        async with self.send_lock:
            await self.ws.send(text)

    # ------------------------------------------------------------------ auth

    async def authenticate(self, ip: str) -> bool:
        try:
            raw = await asyncio.wait_for(self.ws.recv(), AUTH_TIMEOUT)
            env = parse(raw)
        except (asyncio.TimeoutError, ProtocolError):
            await self.ws.close(1008, "auth.hello expected")
            return False
        token = env["payload"].get("token") if env["type"] == "auth.hello" else None
        if not isinstance(token, str) or not self.gw.cfg.token_matches(token):
            self.gw.auth_failures[ip].append(time.monotonic())
            log(f"auth rejected from {ip}")
            await self.send(frame("auth.error", {"code": "auth_failed", "message": "The gateway rejected the access token."}))
            await self.ws.close(1008, "auth failed")
            return False
        a = self.gw.adapter
        await self.send(frame("auth.ok", {
            "session": self.id,
            "agent": {"id": a.agent_id, "name": self.gw.cfg.agent_name or a.agent_name, **({"version": a.version} if a.version else {})},
            "capabilities": self.gw.cfg.capabilities,
            "heartbeatSeconds": self.gw.cfg.heartbeat_seconds,
            "gatewayVersion": __version__,
        }))
        await self.send(frame("agent.status", {"state": "ready"}))
        log(f"client authenticated from {ip} ({self.id})")
        return True

    # ------------------------------------------------------------------ loop

    async def loop(self) -> None:
        async for raw in self.ws:
            try:
                env = parse(raw)
            except ProtocolError as err:
                await self.send(error_frame(err))
                continue
            t, rid, payload = env["type"], env.get("requestId"), env["payload"]
            if t == "ping":
                await self.send(frame("pong"))
            elif t == "message.send":
                self._spawn(rid, self.run_message(rid, env.get("conversationId"), payload))
            elif t == "request.cancel":
                task = self.tasks.get(rid or "")
                if task:
                    task.cancel()
            elif t == "rpc.call":
                self._spawn(rid, self.run_rpc(rid, payload))
            elif t == "stream.subscribe":
                self._spawn(rid, self.run_stream(rid, payload))
            elif t == "stream.unsubscribe":
                task = self.tasks.get(rid or "")
                if task:
                    task.cancel()
            else:
                await self.send(error_frame(ProtocolError("bad_request", f"Unknown frame type {t}"), rid))

    def _spawn(self, rid: str | None, coro) -> None:
        if not valid_uuid(rid):
            coro.close()
            asyncio.create_task(self.send(error_frame(ProtocolError("bad_request", "requestId must be a UUID"))))
            return
        if rid in self.tasks:
            coro.close()
            asyncio.create_task(self.send(error_frame(ProtocolError("bad_request", "Duplicate requestId"), rid)))
            return
        task = asyncio.create_task(coro)
        self.tasks[rid] = task
        task.add_done_callback(lambda _: self.tasks.pop(rid, None))

    async def shutdown(self) -> None:
        for task in list(self.tasks.values()):
            task.cancel()
        if self.tasks:
            await asyncio.gather(*self.tasks.values(), return_exceptions=True)

    # ------------------------------------------------------------------ chat

    async def run_message(self, rid: str, cid: str | None, payload: dict) -> None:
        content = payload.get("content")
        if not valid_uuid(cid) or not isinstance(content, str) or not content.strip():
            await self.send(error_frame(ProtocolError("bad_request", "message.send needs a conversationId UUID and content"), rid, cid))
            return
        if len(content) > MAX_CONTENT_CHARS:
            await self.send(error_frame(ProtocolError("bad_request", "Message is too long"), rid, cid))
            return
        cid = cid.lower()
        if cid in self.gw.busy_conversations:
            await self.send(error_frame(ProtocolError("busy", "This conversation is still answering"), rid, cid))
            return
        self.gw.busy_conversations.add(cid)
        conv = self.gw.store.load(cid)

        async def emit(kind: str, data: dict) -> None:
            mapping = {"status": "agent.status", "delta": "message.delta", "title": "conversation.title"}
            await self.send(frame(mapping.get(kind, kind), data, rid, cid))

        try:
            await self.send(frame("request.accepted", {}, rid, cid))
            history = await self.gw.adapter.run(RunContext(cid, content, conv["messages"], emit))
            title = conv.get("title") or " ".join(content.split()[:6])[:60]
            preview = next((m.get("content") for m in reversed(history) if m.get("role") == "assistant" and isinstance(m.get("content"), str)), "") or ""
            self.gw.store.save(cid, history, title=title, preview=preview)
            await self.send(frame("agent.status", {"state": "ready"}, rid, cid))
            await self.send(frame("message.completed", {}, rid, cid))
        except asyncio.CancelledError:
            await self._safe_send(error_frame(ProtocolError("cancelled", "Stopped"), rid, cid))
            await self._safe_send(frame("agent.status", {"state": "ready"}))
            raise
        except ProtocolError as err:
            await self.send(error_frame(err, rid, cid))
            await self.send(frame("agent.status", {"state": "ready"}))
        except Exception as exc:  # never leak internals to the client
            log("adapter error:", repr(exc))
            await self.send(error_frame(ProtocolError("agent_unavailable", "The agent failed — see gateway logs"), rid, cid))
            await self.send(frame("agent.status", {"state": "ready"}))
        finally:
            self.gw.busy_conversations.discard(cid)

    async def _safe_send(self, text: str) -> None:
        try:
            await self.send(text)
        except Exception:
            pass

    # ------------------------------------------------------------------ rpc

    async def run_rpc(self, rid: str, payload: dict) -> None:
        method = payload.get("method")
        params = payload.get("params") or {}
        try:
            result = await self.dispatch(method, params)
            await self.send(frame("rpc.result", {"result": result}, rid))
        except asyncio.CancelledError:
            raise
        except ProtocolError as err:
            await self.send(error_frame(err, rid))
        except (OSError, ValueError) as exc:
            await self.send(error_frame(ProtocolError("command_failed", str(exc)[:300]), rid))
        except Exception as exc:
            log("rpc error:", method, repr(exc))
            await self.send(error_frame(ProtocolError("internal", "Gateway error — see gateway logs"), rid))

    async def dispatch(self, method: str, p: dict) -> Any:
        gw = self.gw
        fs = gw.files
        if method == "conversations.list":
            return gw.store.summaries()
        if method == "tool.execute":
            raise ProtocolError("not_implemented", "Direct tool execution isn't exposed by this gateway")
        if method == "vps.info":
            return server_info()
        if method == "vps.metrics":
            return gw.sampler.sample()
        if method == "vps.services":
            return await gw.services.list()
        if method == "vps.processes":
            return await asyncio.to_thread(processes)
        if method == "vps.service.action":
            return await gw.services.perform(str(p.get("name", "")), str(p.get("action", "")))
        if method == "terminal.open":
            return gw.terminal.open()
        if method == "terminal.close":
            await gw.terminal.close(str(p.get("sessionId", "")))
            return None
        if method == "terminal.interrupt":
            await gw.terminal.get(str(p.get("sessionId", ""))).interrupt()
            return None
        if method == "fs.roots":
            return fs.list_roots()
        if method == "fs.list":
            return await asyncio.to_thread(fs.list, str(p.get("path", "")))
        if method == "fs.read":
            return await asyncio.to_thread(fs.read, str(p.get("path", "")))
        if method == "fs.write":
            text = p.get("text")
            if not isinstance(text, str):
                raise ProtocolError("bad_request", "text must be a string")
            return await asyncio.to_thread(fs.write, str(p.get("path", "")), text, p.get("expectedVersion"))
        if method == "fs.createFile":
            return await asyncio.to_thread(fs.create, str(p.get("path", "")), False)
        if method == "fs.createDirectory":
            return await asyncio.to_thread(fs.create, str(p.get("path", "")), True)
        if method == "fs.rename":
            return await asyncio.to_thread(fs.rename, str(p.get("path", "")), str(p.get("newName", "")))
        if method == "fs.delete":
            await asyncio.to_thread(fs.delete, str(p.get("path", "")))
            return None
        if method == "fs.search":
            return await asyncio.to_thread(fs.search, str(p.get("query", "")), str(p.get("path", "")))
        if method == "logs.recent":
            return await gw.logs.recent(int(p.get("limit", 100)))
        raise ProtocolError("not_implemented", f"Unknown method {method}")

    # ------------------------------------------------------------------ streams

    async def run_stream(self, rid: str, payload: dict) -> None:
        method = payload.get("method")
        p = payload.get("params") or {}
        try:
            if method == "vps.metrics":
                interval = min(max(float(p.get("intervalSeconds", 2)), 0.5), 60)
                while True:
                    await self.send(frame("stream.data", self.gw.sampler.sample(), rid))
                    await asyncio.sleep(interval)
            elif method == "logs.stream":
                cats = set(p.get("categories") or [])
                async for entry in self.gw.logs.follow(cats):
                    await self.send(frame("stream.data", entry, rid))
            elif method == "terminal.run":
                command = p.get("command")
                if not isinstance(command, str) or not command.strip():
                    raise ProtocolError("bad_request", "command is required")
                session = self.gw.terminal.get(str(p.get("sessionId", "")))
                log(f"terminal.run session={session.id[:8]} cmd={command[:120]!r}")
                async for chunk in session.run(command):
                    await self.send(frame("stream.data", chunk, rid))
            else:
                raise ProtocolError("not_implemented", f"Unknown stream {method}")
            await self.send(frame("stream.end", {}, rid))
        except asyncio.CancelledError:
            raise
        except ProtocolError as err:
            await self._safe_send(error_frame(err, rid))
        except Exception as exc:
            log("stream error:", method, repr(exc))
            await self._safe_send(error_frame(ProtocolError("internal", "Gateway stream failed"), rid))


def json_dumps(value: Any) -> str:  # pragma: no cover - helper for CLI
    return json.dumps(value, indent=2, default=str)
