"""Gateway-owned terminal sessions (disabled by default).

Each command runs in its own process group via `bash -c`, so an interrupt
only stops that command. The session remembers the working directory
across commands (the shell reports its final `pwd` on a passed pipe fd)."""
from __future__ import annotations

import asyncio
import os
import shlex
import signal
import time
import uuid

from .protocol import ProtocolError, iso

COMMAND_TIMEOUT = 15 * 60
MAX_SESSIONS = 6


class TerminalSession:
    def __init__(self, shell: str, cwd: str):
        self.id = str(uuid.uuid4())
        self.shell = shell
        self.cwd = cwd if os.path.isdir(cwd) else "/"
        self.created = time.time()
        self.proc: asyncio.subprocess.Process | None = None

    def describe(self) -> dict:
        return {"id": self.id, "title": os.uname().nodename, "workingDirectory": self.cwd,
                "createdAt": iso(self.created), "state": "running" if self.proc and self.proc.returncode is None else "idle"}

    async def run(self, command: str):
        if self.proc and self.proc.returncode is None:
            raise ProtocolError("busy", "A command is already running in this session")
        r, w = os.pipe()
        os.set_blocking(r, False)  # background jobs may keep the pipe open
        script = f"cd {shlex.quote(self.cwd)} || exit 1\n{command}\n__bb_status=$?\npwd >&{w}\nexit $__bb_status\n"
        self.proc = await asyncio.create_subprocess_exec(
            self.shell, "-c", script,
            stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            pass_fds=(w,), start_new_session=True,
            env={**os.environ, "TERM": "dumb"},
        )
        os.close(w)
        queue: asyncio.Queue = asyncio.Queue()

        async def pump(stream, kind):
            while True:
                chunk = await stream.read(4096)
                if not chunk:
                    break
                await queue.put({"stream": kind, "data": chunk.decode("utf-8", "replace")})
            await queue.put(None)

        tasks = [asyncio.create_task(pump(self.proc.stdout, "stdout")), asyncio.create_task(pump(self.proc.stderr, "stderr"))]
        finished = 0
        deadline = time.monotonic() + COMMAND_TIMEOUT
        try:
            while finished < 2:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    await self.interrupt()
                    yield {"stream": "stderr", "data": "\n[brainbox] command timed out\n"}
                    break
                item = await asyncio.wait_for(queue.get(), timeout=remaining)
                if item is None:
                    finished += 1
                else:
                    yield item
            code = await self.proc.wait()
            try:
                new_cwd = os.read(r, 4096).decode("utf-8", "replace").strip()
            except BlockingIOError:
                new_cwd = ""
            if new_cwd and os.path.isdir(new_cwd):
                self.cwd = new_cwd
            yield {"stream": "exit", "code": code if code >= 0 else 128 - code}
        finally:
            os.close(r)
            for t in tasks:
                t.cancel()
            await self.interrupt()

    async def interrupt(self) -> None:
        proc = self.proc
        if not proc or proc.returncode is not None:
            return
        try:
            os.killpg(proc.pid, signal.SIGINT)
            await asyncio.wait_for(proc.wait(), timeout=3)
        except (ProcessLookupError, asyncio.TimeoutError):
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


class TerminalManager:
    def __init__(self, enabled: bool, shell: str, cwd: str):
        self.enabled = enabled
        self.shell = shell
        self.cwd = cwd
        self.sessions: dict[str, TerminalSession] = {}

    def _require(self) -> None:
        if not self.enabled:
            raise ProtocolError("permission_denied", "The terminal is disabled in the gateway config")

    def open(self) -> dict:
        self._require()
        if len(self.sessions) >= MAX_SESSIONS:
            raise ProtocolError("busy", "Too many terminal sessions")
        s = TerminalSession(self.shell, self.cwd)
        self.sessions[s.id] = s
        return s.describe()

    def get(self, session_id: str) -> TerminalSession:
        self._require()
        s = self.sessions.get(session_id)
        if not s:
            raise ProtocolError("not_found", "Terminal session closed")
        return s

    async def close(self, session_id: str) -> None:
        s = self.sessions.pop(session_id, None)
        if s:
            await s.interrupt()

    async def close_all(self) -> None:
        for sid in list(self.sessions):
            await self.close(sid)
