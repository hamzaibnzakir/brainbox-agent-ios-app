"""Gateway-side conversation store.

Hermes' library API keeps conversation state caller-managed (you pass the
previous `messages` back as `conversation_history`), so the gateway owns the
history for app conversations. App chats get their own sessions and never
reuse the Telegram DM session.
"""
from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path


class ConversationStore:
    def __init__(self, directory: str | os.PathLike, max_messages: int = 400):
        self.dir = Path(directory) / "conversations"
        self.dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)
        self.max_messages = max_messages
        self._lock = threading.Lock()

    def _path(self, conversation_id: str) -> Path:
        # conversation ids are validated UUIDs before reaching here
        return self.dir / f"{conversation_id}.json"

    def load(self, conversation_id: str) -> dict:
        with self._lock:
            path = self._path(conversation_id)
            if not path.exists():
                return {"id": conversation_id, "title": "", "updatedAt": time.time(), "messages": [], "preview": ""}
            return json.loads(path.read_text())

    def save(self, conversation_id: str, messages: list, title: str | None = None, preview: str = "") -> None:
        with self._lock:
            path = self._path(conversation_id)
            existing = json.loads(path.read_text()) if path.exists() else {}
            data = {
                "id": conversation_id,
                "title": title or existing.get("title") or "",
                "updatedAt": time.time(),
                "messages": messages[-self.max_messages:],
                "preview": preview[:200],
            }
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps(data, ensure_ascii=False))
            os.chmod(tmp, 0o600)
            tmp.replace(path)

    def summaries(self) -> list[dict]:
        with self._lock:
            items = []
            for p in self.dir.glob("*.json"):
                try:
                    d = json.loads(p.read_text())
                except (OSError, json.JSONDecodeError):
                    continue
                items.append({"id": d["id"], "title": d.get("title") or "Conversation", "updatedAt": d.get("updatedAt", 0), "preview": d.get("preview", "")})
            return sorted(items, key=lambda x: x["updatedAt"], reverse=True)
