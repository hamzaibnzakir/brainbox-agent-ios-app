"""Brainbox Agent Protocol v1 frames (see docs/AGENT_PROTOCOL.md)."""
from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from typing import Any

VERSION = 1

TERMINAL_TYPES = {"message.completed", "error", "rpc.result", "stream.end"}

TOOL_KINDS = {"terminal", "file", "search", "browser", "code", "system", "service", "git", "network", "other"}


class ProtocolError(Exception):
    def __init__(self, code: str, message: str, retryable: bool = False):
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable

    def payload(self) -> dict:
        return {"code": self.code, "message": self.message, "retryable": self.retryable}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def frame(type_: str, payload: Any = None, request_id: str | None = None, conversation_id: str | None = None) -> str:
    env: dict[str, Any] = {
        "v": VERSION,
        "type": type_,
        "id": "evt_" + uuid.uuid4().hex,
        "ts": now_iso(),
        "payload": {} if payload is None else payload,
    }
    if request_id:
        env["requestId"] = request_id
    if conversation_id:
        env["conversationId"] = conversation_id
    return json.dumps(env, separators=(",", ":"), ensure_ascii=False)


def parse(text: str | bytes) -> dict:
    if isinstance(text, bytes):
        text = text.decode("utf-8")
    try:
        env = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ProtocolError("bad_frame", "Frame is not valid JSON") from exc
    if not isinstance(env, dict) or env.get("v") != VERSION or not isinstance(env.get("type"), str):
        raise ProtocolError("bad_frame", f"Expected protocol v{VERSION} envelope")
    if not isinstance(env.get("payload", {}), dict) and env.get("payload") is not None:
        raise ProtocolError("bad_frame", "payload must be an object")
    env.setdefault("payload", {})
    return env


def error_frame(err: ProtocolError, request_id: str | None = None, conversation_id: str | None = None) -> str:
    return frame("error", err.payload(), request_id, conversation_id)


def valid_uuid(value: str | None) -> bool:
    if not value:
        return False
    try:
        uuid.UUID(value)
        return True
    except ValueError:
        return False
