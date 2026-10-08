import asyncio
import json
import uuid

import pytest
import pytest_asyncio
from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

from brainbox_gateway import config as cfgmod
from brainbox_gateway.server import Gateway

TOKEN = "test-token-0123456789abcdefghijklmnop"


def make_config(tmp_path, **overrides):
    roots = tmp_path / "roots"
    (roots / "home").mkdir(parents=True)
    (roots / "logs").mkdir()
    (roots / "home" / "notes.md").write_text("# hi\n")
    (roots / "logs" / "app.log").write_text("line\n")
    raw = {
        "server": {"host": "127.0.0.1", "port": 0, "data_dir": str(tmp_path / "data"), "heartbeat_seconds": 20},
        "auth": {"token_sha256": cfgmod.hash_token(TOKEN), "max_failures_per_minute": 3},
        "agent": {"adapter": "echo", "name": "Echo"},
        "system": {
            "file_roots": [{"path": str(roots / "home")}, {"path": str(roots / "logs"), "read_only": True}],
            "services": [],
            "log_units": [],
        },
        "terminal": {"enabled": True, "shell": "/bin/bash", "cwd": str(roots / "home")},
    }
    for key, value in overrides.items():
        section, field = key.split("__")
        raw.setdefault(section, {})[field] = value
    return cfgmod.from_dict(raw)


class Client:
    def __init__(self, ws):
        self.ws = ws

    async def send(self, type_, payload=None, request_id=None, conversation_id=None):
        env = {"v": 1, "type": type_, "id": "evt_" + uuid.uuid4().hex, "ts": "2026-10-08T00:00:00Z", "payload": payload or {}}
        if request_id:
            env["requestId"] = request_id
        if conversation_id:
            env["conversationId"] = conversation_id
        await self.ws.send(json.dumps(env))

    async def recv(self, timeout=5):
        return json.loads(await asyncio.wait_for(self.ws.recv(), timeout))

    async def until_terminal(self, request_id, timeout=10):
        frames = []
        while True:
            f = await self.recv(timeout)
            if f.get("requestId") != request_id:
                continue
            frames.append(f)
            if f["type"] in ("message.completed", "error", "rpc.result", "stream.end"):
                return frames

    async def rpc(self, method, params=None):
        rid = str(uuid.uuid4())
        await self.send("rpc.call", {"method": method, "params": params or {}}, rid)
        frames = await self.until_terminal(rid)
        last = frames[-1]
        if last["type"] == "error":
            return {"error": last["payload"]}
        return last["payload"]["result"]


@pytest_asyncio.fixture
async def gateway_factory(tmp_path):
    servers = []

    async def start(adapter=None, **overrides):
        cfg = make_config(tmp_path, **overrides)
        gw = Gateway(cfg, adapter=adapter)
        server = await serve(gw.handle, "127.0.0.1", 0)
        servers.append(server)
        port = server.sockets[0].getsockname()[1]
        return gw, f"ws://127.0.0.1:{port}{cfg.path}"

    yield start
    for s in servers:
        s.close()
        await s.wait_closed()


@pytest_asyncio.fixture
async def connect_client():
    opened = []

    async def open_(url, token=TOKEN, hello=True):
        ws = await connect(url)
        opened.append(ws)
        client = Client(ws)
        if hello:
            await client.send("auth.hello", {"token": token, "client": "test", "clientVersion": "0", "platform": "ios", "protocolVersion": 1})
        return client

    yield open_
    for ws in opened:
        await ws.close()
