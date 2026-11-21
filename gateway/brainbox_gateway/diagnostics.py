"""Read-only server overview for the app's Server screen.

Every number comes from the kernel (``/proc``, ``statvfs``) or from a live request to
Hermes at the moment of asking; nothing is estimated or invented. Fields that can't be
read are ``null`` and the app shows "unavailable". Nothing here changes anything.
"""
from __future__ import annotations

import os
import platform
import shutil
import socket
import time
from typing import Any


def _meminfo() -> dict[str, int] | None:
    try:
        values: dict[str, int] = {}
        with open("/proc/meminfo", encoding="ascii") as fh:
            for line in fh:
                name, _, rest = line.partition(":")
                parts = rest.split()
                if parts and parts[0].isdigit():
                    values[name] = int(parts[0]) * 1024
        total, available = values.get("MemTotal"), values.get("MemAvailable")
        if total is None or available is None:
            return None
        return {"total_bytes": total, "available_bytes": available,
                "swap_total_bytes": values.get("SwapTotal"), "swap_free_bytes": values.get("SwapFree")}
    except OSError:
        return None


def _uptime() -> float | None:
    try:
        with open("/proc/uptime", encoding="ascii") as fh:
            return float(fh.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def _disk(path: str) -> dict[str, Any] | None:
    try:
        usage = shutil.disk_usage(path)
    except OSError:
        return None
    return {"path": path, "total_bytes": usage.total, "used_bytes": usage.used, "free_bytes": usage.free}


def _os_name() -> str | None:
    try:
        with open("/etc/os-release", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return platform.system() or None


def host_snapshot(disk_paths: list[str]) -> dict[str, Any]:
    try:
        load = list(os.getloadavg())
    except OSError:
        load = None
    seen: set[str] = set()
    disks = []
    for p in disk_paths:
        if p and p not in seen and (d := _disk(p)):
            seen.add(p)
            disks.append(d)
    return {"hostname": socket.gethostname(), "os": _os_name(), "kernel": platform.release() or None,
            "uptime_seconds": _uptime(), "load_average": load, "cpu_count": os.cpu_count(),
            "memory": _meminfo(), "disks": disks, "sampled_at": round(time.time(), 3)}
