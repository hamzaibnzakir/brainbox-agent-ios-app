"""Brainbox-owned chat sessions: ownership, read-only listing and verified deletion.

Facts this module relies on (hermes-agent 284d220):

* ``DELETE /api/sessions/{id}`` → ``SessionDB.delete_session(id)`` removes the session row,
  its ``messages`` rows (FTS rows follow via trigger) and its *delegate* (sub-agent) children.
  Compression continuations (children whose parent has ``end_reason='compression'``) are only
  orphaned, and the API passes no ``sessions_dir`` so ``<id>.json[l]`` / ``request_dump_<id>_*.json``
  files under ``~/.hermes/sessions`` are left behind.
* ``GET /api/sessions`` cannot list archived sessions and projects a compressed conversation under
  its tip id (``_lineage_root_id`` = root).

So the proxy (not Hermes) provides: a per-device ownership registry, a read-only listing of the
app's own ``ios_`` conversations (active or archived) straight from ``state.db`` opened read-only,
and a cascade delete that removes the continuation chain and leftover files, all through Hermes'
own delete API, then verifies nothing remains. Nothing here ever writes to ``state.db``.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import tempfile
import time
from pathlib import Path
from typing import Any
from urllib.parse import quote

# Exactly the ids HermesAgentProvider.sessionID(for:) creates: "ios_" + 32 lowercase hex.
APP_SESSION_RE = re.compile(r"^ios_[0-9a-f]{32}$")
# Any Hermes session id we might pass to a filesystem glob or URL (no separators, no "..").
SAFE_SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_.:\-]{1,256}$")


def is_app_session(session_id: str) -> bool:
    return bool(APP_SESSION_RE.fullmatch(session_id or ""))


def is_safe_session_id(session_id: str) -> bool:
    return bool(SAFE_SESSION_ID_RE.fullmatch(session_id or "")) and session_id not in {".", ".."} and ".." not in session_id


# --------------------------------------------------------------------------- ownership

class OwnershipRegistry:
    """Which device created (or first managed) each ``ios_`` session.

    Stored as JSON (mode 600) in the proxy's state dir. Sessions created before this registry
    existed have no owner; the first device that manages one claims it."""

    def __init__(self, path: str) -> None:
        self.path = Path(path)

    def _load(self) -> dict[str, Any]:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            return data if isinstance(data, dict) and isinstance(data.get("sessions"), dict) else {"version": 1, "sessions": {}}
        except (OSError, ValueError):
            return {"version": 1, "sessions": {}}

    def _save(self, data: dict[str, Any]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".owners-", dir=str(self.path.parent))
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

    def owner(self, session_id: str) -> str | None:
        entry = self._load()["sessions"].get(session_id)
        return entry.get("owner") if isinstance(entry, dict) else None

    def record(self, session_id: str, device_key: str) -> None:
        data = self._load()
        if session_id not in data["sessions"]:
            data["sessions"][session_id] = {"owner": device_key, "since": round(time.time(), 3)}
            self._save(data)

    def forget(self, session_id: str) -> None:
        data = self._load()
        if data["sessions"].pop(session_id, None) is not None:
            self._save(data)

    def owners(self) -> dict[str, str]:
        return {sid: e.get("owner") for sid, e in self._load()["sessions"].items() if isinstance(e, dict)}

    def may_manage(self, session_id: str, device_key: str, admin: bool = False) -> bool:
        owner = self.owner(session_id)
        return owner is None or owner == device_key or admin


# --------------------------------------------------------------------------- read-only store

class SessionStoreUnavailable(RuntimeError):
    pass


class ReadOnlySessionStore:
    """Read-only view of Hermes' ``state.db`` (``mode=ro``: SQLite refuses every write)."""

    def __init__(self, db_path: str) -> None:
        self.db_path = db_path

    def _connect(self) -> sqlite3.Connection:
        if not Path(self.db_path).exists():
            raise SessionStoreUnavailable("Hermes session database not found")
        try:
            conn = sqlite3.connect(f"file:{quote(self.db_path)}?mode=ro", uri=True, timeout=5)
        except sqlite3.Error as exc:
            raise SessionStoreUnavailable(str(exc)) from exc
        conn.row_factory = sqlite3.Row
        return conn

    def _query(self, sql: str, params: tuple = ()) -> list[sqlite3.Row]:
        conn = self._connect()
        try:
            return conn.execute(sql, params).fetchall()
        except sqlite3.Error as exc:
            raise SessionStoreUnavailable(str(exc)) from exc
        finally:
            conn.close()

    def list_app_sessions(self, *, archived: bool, limit: int = 100, offset: int = 0) -> list[dict[str, Any]]:
        """The app's own conversations (root ``ios_`` rows), newest activity first."""
        rows = self._query(
            r"""SELECT s.id, s.title, s.started_at, s.ended_at, s.message_count, s.archived,
                       COALESCE((SELECT MAX(m.timestamp) FROM messages m WHERE m.session_id = s.id),
                                s.started_at) AS last_active
                FROM sessions s
                WHERE s.id LIKE 'ios\_%' ESCAPE '\' AND s.archived = ?
                ORDER BY last_active DESC, s.id DESC LIMIT ? OFFSET ?""",
            (1 if archived else 0, int(limit) + 1, int(offset)))
        return [{"id": r["id"], "title": r["title"], "started_at": r["started_at"], "ended_at": r["ended_at"],
                 "message_count": r["message_count"], "archived": bool(r["archived"]), "last_active": r["last_active"]}
                for r in rows if is_app_session(r["id"])]

    def exists(self, session_id: str) -> bool:
        return bool(self._query("SELECT 1 FROM sessions WHERE id = ? LIMIT 1", (session_id,)))

    # One forward step of Hermes' own get_compression_chain (hermes_state_compression.py
    # _CHAIN_STEP_SQL, 284d220): the preferred continuation child, never a fork (/branch),
    # a delegate (sub-agent) or a tool session.
    _CHAIN_STEP_SQL = """
        SELECT child.id
        FROM sessions parent
        JOIN sessions child ON child.parent_session_id = parent.id
        WHERE parent.id = ?
          AND parent.end_reason = 'compression'
          AND json_extract(child.model_config, '$._branched_from') IS NULL
          AND json_extract(child.model_config, '$._delegate_from') IS NULL
          AND COALESCE(child.source, '') != 'tool'
        ORDER BY CASE WHEN child.end_reason = 'compression' THEN 0
                      WHEN child.ended_at IS NULL THEN 1 ELSE 2 END,
                 child.started_at DESC, child.id DESC
        LIMIT 1"""

    def continuation_chain(self, root_id: str) -> list[str]:
        """Compression continuations of ``root_id``, deepest first (delete order). Forks and
        sub-agent sessions are separate conversations and are never included."""
        chain: list[str] = []
        current = root_id
        for _ in range(500):
            rows = self._query(self._CHAIN_STEP_SQL, (current,))
            if not rows or rows[0]["id"] in chain or rows[0]["id"] == root_id:
                break
            current = rows[0]["id"]
            if not is_safe_session_id(current):
                break
            chain.append(current)
        return list(reversed(chain))

    def message_count(self, session_ids: list[str]) -> int:
        if not session_ids:
            return 0
        marks = ",".join("?" for _ in session_ids)
        return int(self._query(f"SELECT COUNT(*) AS n FROM messages WHERE session_id IN ({marks})", tuple(session_ids))[0]["n"])


# --------------------------------------------------------------------------- leftover files

def remove_session_files(sessions_dir: str, session_id: str) -> list[str]:
    """Delete ``<id>.json``, ``<id>.jsonl`` and ``request_dump_<id>_*.json`` — the files Hermes'
    own CLI delete removes but its HTTP delete leaves behind. Only plain files directly inside
    ``sessions_dir`` whose names are built from a validated id are touched."""
    if not is_safe_session_id(session_id):
        return []
    base = Path(sessions_dir)
    try:
        base_resolved = base.resolve(strict=True)
    except OSError:
        return []
    candidates = [base / f"{session_id}.json", base / f"{session_id}.jsonl"]
    try:
        candidates += [p for p in base.iterdir()
                       if p.name.startswith(f"request_dump_{session_id}_") and p.name.endswith(".json")]
    except OSError:
        pass
    removed: list[str] = []
    for path in candidates:
        try:
            if path.is_symlink() or not path.is_file() or path.resolve().parent != base_resolved:
                continue
            path.unlink()
            removed.append(path.name)
        except OSError:
            continue
    return removed
