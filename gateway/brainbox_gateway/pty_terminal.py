"""Direct VPS terminal: a real interactive PTY over an authenticated WebSocket.

Off by default. When enabled, every shell runs as ONE dedicated least-privilege account
(``[terminal] user``, never root) with a scrubbed environment, so it can't read the Hermes
API key, the device-token hashes or anything else the proxy can. Sessions survive a dropped
connection for ``detach_grace_seconds`` (scrollback is replayed on reattach), are killed
after ``idle_timeout_seconds`` without input, and are limited per device.

Wire protocol (JSON text frames)::

    client → {"type":"input","data":"ls\\r"} | {"type":"resize","cols":120,"rows":40}
             {"type":"interrupt"} | {"type":"close"}
    server → {"type":"ready","session":id,"user":name,"reattached":bool,"cols":c,"rows":r}
             {"type":"output","data":"..."} | {"type":"exit","code":n} | {"type":"error","code":c,"message":m}

Keystrokes and output are never logged; the audit log records open/reattach/close only.
"""
from __future__ import annotations

import asyncio
import codecs
import fcntl
import json
import logging
import os
import pwd
import re
import secrets
import shutil
import signal
import struct
import subprocess
import termios
import time
from collections import deque
from dataclasses import dataclass
from typing import Any, Callable

log = logging.getLogger("brainbox.terminal")

SESSION_RE = re.compile(r"^[A-Za-z0-9_-]{16,64}$")


@dataclass
class TerminalConfig:
    enabled: bool = False
    user: str = ""
    shell: str = "/bin/bash"
    cwd: str = ""                      # default: the account's home directory
    idle_timeout_seconds: int = 1800
    detach_grace_seconds: int = 300
    max_sessions_per_device: int = 3
    scrollback_bytes: int = 65536

    @staticmethod
    def from_dict(raw: dict[str, Any]) -> "TerminalConfig":
        cfg = TerminalConfig(
            enabled=bool(raw.get("enabled", False)), user=str(raw.get("user", "")), shell=str(raw.get("shell", "/bin/bash")),
            cwd=str(raw.get("cwd", "")), idle_timeout_seconds=int(raw.get("idle_timeout_seconds", 1800)),
            detach_grace_seconds=int(raw.get("detach_grace_seconds", 300)),
            max_sessions_per_device=int(raw.get("max_sessions_per_device", 3)),
            scrollback_bytes=int(raw.get("scrollback_bytes", 65536)))
        if cfg.enabled:
            if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", cfg.user):
                raise ValueError("terminal.user must name the dedicated least-privilege account (e.g. \"brainbox-term\")")
            if cfg.user == "root":
                raise ValueError("terminal.user must not be root")
            if not cfg.shell.startswith("/"):
                raise ValueError("terminal.shell must be an absolute path")
        if not (60 <= cfg.idle_timeout_seconds <= 86400 and 0 <= cfg.detach_grace_seconds <= 3600
                and 1 <= cfg.max_sessions_per_device <= 10 and 4096 <= cfg.scrollback_bytes <= 1_048_576):
            raise ValueError("terminal limits out of range")
        return cfg


class TerminalUnavailable(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def account(cfg: TerminalConfig) -> pwd.struct_passwd:
    """The account shells run as. Root is never allowed; a non-root proxy can only run
    shells as itself (so the configured user must be the proxy's own account)."""
    try:
        entry = pwd.getpwnam(cfg.user)
    except KeyError as exc:
        raise TerminalUnavailable("terminal_user_missing", f"The terminal account “{cfg.user}” doesn't exist on the server.") from exc
    if entry.pw_uid == 0:
        raise TerminalUnavailable("terminal_user_root", "The terminal account must not be root.")
    if os.geteuid() != 0 and entry.pw_uid != os.geteuid():
        raise TerminalUnavailable("terminal_user_mismatch", "The proxy can't switch to the terminal account.")
    return entry


def clean_env(entry: pwd.struct_passwd, shell: str) -> dict[str, str]:
    """A minimal environment — nothing inherited from the proxy (keys, tokens, paths)."""
    return {"HOME": entry.pw_dir, "USER": entry.pw_name, "LOGNAME": entry.pw_name, "SHELL": shell,
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "TERM": "xterm-256color", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"}


def set_winsize(fd: int, rows: int, cols: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


class PtySession:
    def __init__(self, cfg: TerminalConfig, owner: str, cols: int, rows: int) -> None:
        self.cfg = cfg
        self.owner = owner
        self.id = secrets.token_urlsafe(24)
        self.cols, self.rows = cols, rows
        self.created = time.time()
        self.last_input = time.monotonic()
        self.detached_at: float | None = None
        self.scrollback: deque[bytes] = deque()
        self._scroll_size = 0
        self.listener: Callable[[dict[str, Any]], None] | None = None
        self.exit_code: int | None = None
        self.proc: subprocess.Popen | None = None
        self.master: int = -1
        self.user = ""

    def start(self) -> None:
        entry = account(self.cfg)
        self.user = entry.pw_name
        if not os.path.isfile(self.cfg.shell) or not os.access(self.cfg.shell, os.X_OK):
            raise TerminalUnavailable("terminal_shell_missing", "The configured shell doesn't exist.")
        setsid = shutil.which("setsid")
        if not setsid:
            raise TerminalUnavailable("terminal_setsid_missing", "util-linux `setsid` is required on the server.")
        cwd = self.cfg.cwd or entry.pw_dir
        if not os.path.isdir(cwd):
            cwd = "/tmp"
        master, slave = os.openpty()
        set_winsize(slave, self.rows, self.cols)
        kwargs: dict[str, Any] = {}
        if os.geteuid() == 0:
            kwargs.update(user=entry.pw_uid, group=entry.pw_gid, extra_groups=[])
        try:
            # `setsid -c` makes the PTY the controlling terminal, so Ctrl-C, job control
            # and full-screen programs behave exactly like an SSH session.
            self.proc = subprocess.Popen([setsid, "-c", self.cfg.shell, "-l"], stdin=slave, stdout=slave, stderr=slave,
                                         cwd=cwd, env=clean_env(entry, self.cfg.shell), close_fds=True, **kwargs)
        finally:
            os.close(slave)
        os.set_blocking(master, False)
        self.master = master
        asyncio.get_running_loop().add_reader(master, self._on_readable)
        self._decoder = codecs.getincrementaldecoder("utf-8")("replace")

    # -- I/O -------------------------------------------------------------------------

    def _on_readable(self) -> None:
        try:
            data = os.read(self.master, 65536)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if not data:
            self._finish()
            return
        self.scrollback.append(data)
        self._scroll_size += len(data)
        while self._scroll_size > self.cfg.scrollback_bytes and len(self.scrollback) > 1:
            self._scroll_size -= len(self.scrollback.popleft())
        if self.listener:
            text = self._decoder.decode(data)
            if text:
                self.listener({"type": "output", "data": text})

    def _finish(self) -> None:
        if self.master >= 0:
            try:
                asyncio.get_running_loop().remove_reader(self.master)
            except (RuntimeError, ValueError):
                pass
            try:
                os.close(self.master)
            except OSError:
                pass
            self.master = -1
        if self.proc is not None:
            try:
                self.exit_code = self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.exit_code = None
        if self.listener:
            self.listener({"type": "exit", "code": self.exit_code if self.exit_code is not None else -1})

    @property
    def alive(self) -> bool:
        return self.master >= 0 and self.proc is not None and self.proc.poll() is None

    def write(self, text: str) -> None:
        if self.master < 0:
            return
        self.last_input = time.monotonic()
        data = text.encode("utf-8")
        while data:
            try:
                n = os.write(self.master, data)
            except BlockingIOError:
                time.sleep(0.005)
                continue
            data = data[n:]

    def resize(self, cols: int, rows: int) -> None:
        self.cols, self.rows = cols, rows
        if self.master >= 0:
            set_winsize(self.master, rows, cols)
            if self.proc and self.proc.poll() is None:
                try:
                    os.killpg(os.getpgid(self.proc.pid), signal.SIGWINCH)
                except OSError:
                    pass

    def interrupt(self) -> None:
        self.write("\x03")

    def replay(self) -> str:
        return b"".join(self.scrollback).decode("utf-8", "replace")

    def terminate(self) -> None:
        proc = self.proc
        if proc and proc.poll() is None:
            for sig in (signal.SIGHUP, signal.SIGTERM):
                try:
                    os.killpg(os.getpgid(proc.pid), sig)
                except OSError:
                    break
                try:
                    proc.wait(timeout=1)
                    break
                except subprocess.TimeoutExpired:
                    continue
            if proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except OSError:
                    pass
        self.listener = None
        self._finish()


class TerminalManager:
    def __init__(self, cfg: TerminalConfig) -> None:
        self.cfg = cfg
        self.sessions: dict[str, PtySession] = {}
        self._reaper: asyncio.Task | None = None

    def count_for(self, owner: str) -> int:
        return sum(1 for s in self.sessions.values() if s.owner == owner and s.alive)

    def open(self, owner: str, cols: int, rows: int) -> PtySession:
        if self.count_for(owner) >= self.cfg.max_sessions_per_device:
            raise TerminalUnavailable("too_many_sessions", "Close another terminal first.")
        session = PtySession(self.cfg, owner, cols, rows)
        session.start()
        self.sessions[session.id] = session
        self._ensure_reaper()
        return session

    def get(self, session_id: str, owner: str) -> PtySession | None:
        session = self.sessions.get(session_id) if SESSION_RE.fullmatch(session_id or "") else None
        if session is None or session.owner != owner or not session.alive:
            return None
        return session

    def close(self, session_id: str) -> None:
        session = self.sessions.pop(session_id, None)
        if session:
            session.terminate()

    def reap(self) -> None:
        now = time.monotonic()
        for sid, s in list(self.sessions.items()):
            idle = now - s.last_input > self.cfg.idle_timeout_seconds
            abandoned = s.detached_at is not None and now - s.detached_at > self.cfg.detach_grace_seconds
            if not s.alive or idle or abandoned:
                self.close(sid)

    def _ensure_reaper(self) -> None:
        if self._reaper is None or self._reaper.done():
            self._reaper = asyncio.get_running_loop().create_task(self._reap_loop())

    async def _reap_loop(self) -> None:
        while self.sessions:
            await asyncio.sleep(5)
            self.reap()

    def shutdown(self) -> None:
        for sid in list(self.sessions):
            self.close(sid)
        if self._reaper:
            self._reaper.cancel()


def parse_client_frame(text: str) -> dict[str, Any] | None:
    try:
        frame = json.loads(text)
    except ValueError:
        return None
    if not isinstance(frame, dict) or frame.get("type") not in ("input", "resize", "interrupt", "close", "ping"):
        return None
    if frame["type"] == "input" and not (isinstance(frame.get("data"), str) and len(frame["data"]) <= 65536):
        return None
    if frame["type"] == "resize":
        cols, rows = frame.get("cols"), frame.get("rows")
        if not (isinstance(cols, int) and isinstance(rows, int) and 10 <= cols <= 500 and 4 <= rows <= 300):
            return None
    return frame
