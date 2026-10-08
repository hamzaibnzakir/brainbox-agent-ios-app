"""VPS metrics, services, processes, logs — served by the gateway itself
(not by Hermes), so they keep working when Hermes is busy or down.
Everything mutating is restricted to explicit allow-lists."""
from __future__ import annotations

import asyncio
import json
import os
import platform
import shutil
import socket
import time
import uuid

import psutil

from .protocol import ProtocolError, iso

# ---------------------------------------------------------------- metrics


class MetricsSampler:
    def __init__(self) -> None:
        self._last_net = psutil.net_io_counters()
        self._last_t = time.monotonic()
        psutil.cpu_percent(interval=None)  # prime

    def sample(self) -> dict:
        now = time.monotonic()
        net = psutil.net_io_counters()
        dt = max(now - self._last_t, 1e-3)
        rx = (net.bytes_recv - self._last_net.bytes_recv) / dt
        tx = (net.bytes_sent - self._last_net.bytes_sent) / dt
        self._last_net, self._last_t = net, now
        mem = psutil.virtual_memory()
        disk = psutil.disk_usage("/")
        try:
            load = list(os.getloadavg())
        except OSError:  # pragma: no cover
            load = []
        return {
            "cpuUsage": round(psutil.cpu_percent(interval=None) / 100.0, 4),
            "memoryUsedBytes": int(mem.total - mem.available),
            "memoryTotalBytes": int(mem.total),
            "diskUsedBytes": int(disk.used),
            "diskTotalBytes": int(disk.total),
            "networkRxBytesPerSecond": max(rx, 0.0),
            "networkTxBytesPerSecond": max(tx, 0.0),
            "loadAverage": load,
            "timestamp": iso(time.time()),
        }


def private_address() -> str | None:
    for addrs in psutil.net_if_addrs().values():
        for a in addrs:
            if a.family == socket.AF_INET and a.address.startswith("100."):
                parts = a.address.split(".")
                if len(parts) == 4 and 64 <= int(parts[1]) <= 127:
                    return a.address
    return None


def server_info() -> dict:
    os_name = platform.platform()
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    os_name = line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return {
        "hostname": platform.node(),
        "operatingSystem": os_name,
        "kernel": platform.release(),
        "architecture": platform.machine(),
        "cpuCores": psutil.cpu_count() or 1,
        "bootedAt": iso(psutil.boot_time()),
        **({"privateAddress": addr} if (addr := private_address()) else {}),
    }


def processes(limit: int = 25) -> list[dict]:
    rows = []
    for p in psutil.process_iter(["pid", "name", "username", "cpu_percent", "memory_info"]):
        info = p.info
        mem = info.get("memory_info")
        rows.append({
            "pid": info["pid"],
            "name": info.get("name") or "?",
            "user": info.get("username") or "?",
            "cpu": float(info.get("cpu_percent") or 0.0),
            "memoryBytes": int(mem.rss) if mem else 0,
        })
    rows.sort(key=lambda r: (r["cpu"], r["memoryBytes"]), reverse=True)
    return rows[:limit]


# ---------------------------------------------------------------- services


async def _run(*cmd: str, timeout: float = 30) -> tuple[int, str, str]:
    proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise ProtocolError("timeout", f"{cmd[0]} timed out", retryable=True)
    return proc.returncode or 0, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def _unit(name: str) -> str:
    return name if "." in name else name + ".service"


class Services:
    def __init__(self, allowed: list[str]):
        self.allowed = [_unit(n) for n in allowed]

    def _check(self, name: str) -> str:
        unit = _unit(name)
        if unit not in self.allowed:
            raise ProtocolError("permission_denied", f"{name} is not in the gateway's service allow-list")
        return unit

    async def status(self, name: str) -> dict:
        unit = self._check(name)
        if not shutil.which("systemctl"):
            return {"name": name, "summary": "systemctl unavailable", "state": "unknown"}
        _, out, _ = await _run("systemctl", "show", unit, "--no-pager",
                               "--property=Description,ActiveState,SubState,MainPID,ActiveEnterTimestampMonotonic,MemoryCurrent")
        props = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
        active = props.get("ActiveState", "unknown")
        state = {"active": "running", "inactive": "stopped", "failed": "failed",
                 "activating": "restarting", "deactivating": "restarting", "reloading": "restarting"}.get(active, "unknown")
        result: dict = {"name": name.removesuffix(".service"), "summary": props.get("Description", ""), "state": state}
        pid = int(props.get("MainPID", "0") or 0)
        if pid:
            result["pid"] = pid
        mono = int(props.get("ActiveEnterTimestampMonotonic", "0") or 0)
        if state == "running" and mono:
            result["since"] = iso(time.time() - (time.monotonic() - mono / 1e6))
        mem = props.get("MemoryCurrent", "")
        if mem.isdigit():
            result["memoryBytes"] = int(mem)
        return result

    async def list(self) -> list[dict]:
        return [await self.status(u) for u in self.allowed]

    async def perform(self, name: str, action: str) -> dict:
        unit = self._check(name)
        if action not in ("start", "stop", "restart"):
            raise ProtocolError("bad_request", "action must be start, stop or restart")
        code, _, err = await _run("systemctl", action, unit, timeout=90)
        if code != 0:
            raise ProtocolError("command_failed", err.strip()[-300:] or f"systemctl {action} failed")
        return await self.status(unit)


# ---------------------------------------------------------------- logs

_LEVELS = {0: "critical", 1: "critical", 2: "critical", 3: "error", 4: "warning", 5: "notice", 6: "info", 7: "debug"}


def _category(unit: str) -> str:
    u = unit.lower()
    if "hermes" in u:
        return "agent"
    if "brainbox-gateway" in u:
        return "gateway"
    if "nginx" in u or "ssh" in u:
        return "server"
    if u.startswith("api") or "api" in u:
        return "api"
    return "services"


def journal_to_entry(raw: dict) -> dict:
    unit = raw.get("_SYSTEMD_UNIT") or raw.get("SYSLOG_IDENTIFIER") or "system"
    msg = raw.get("MESSAGE", "")
    if isinstance(msg, list):  # journald emits byte arrays for binary data
        msg = bytes(x for x in msg if isinstance(x, int)).decode("utf-8", "replace")
    try:
        ts = int(raw.get("__REALTIME_TIMESTAMP", "0")) / 1e6
    except ValueError:
        ts = time.time()
    return {
        "id": str(uuid.uuid4()),
        "timestamp": iso(ts or time.time()),
        "level": _LEVELS.get(int(raw.get("PRIORITY", 6) or 6), "info"),
        "category": _category(str(unit)),
        "source": str(raw.get("SYSLOG_IDENTIFIER") or unit).removesuffix(".service")[:40],
        "message": str(msg)[:4000],
    }


class Logs:
    """Read-only journald access for allow-listed units. Never deletes,
    rotates or vacuums anything."""

    def __init__(self, units: list[str]):
        self.units = [_unit(u) for u in units]

    def _args(self) -> list[str]:
        args = ["journalctl", "--no-pager", "-o", "json"]
        for u in self.units:
            args += ["-u", u]
        return args

    async def recent(self, limit: int) -> list[dict]:
        if not self.units or not shutil.which("journalctl"):
            return []
        _, out, _ = await _run(*self._args(), "-n", str(max(1, min(limit, 500))))
        entries = []
        for line in out.splitlines():
            try:
                entries.append(journal_to_entry(json.loads(line)))
            except (json.JSONDecodeError, TypeError):
                continue
        return entries

    async def follow(self, categories: set[str]):
        if not self.units or not shutil.which("journalctl"):
            return
        proc = await asyncio.create_subprocess_exec(*self._args(), "-f", "-n", "0",
                                                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        try:
            assert proc.stdout
            async for line in proc.stdout:
                try:
                    entry = journal_to_entry(json.loads(line))
                except (json.JSONDecodeError, TypeError):
                    continue
                if not categories or entry["category"] in categories:
                    yield entry
        finally:
            if proc.returncode is None:
                proc.kill()
                await proc.wait()
