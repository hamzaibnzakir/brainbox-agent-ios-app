import asyncio
import uuid

import pytest
from websockets.exceptions import ConnectionClosed

from brainbox_gateway.adapters import EchoAdapter
from brainbox_gateway import config as cfgmod


async def authed(gateway_factory, connect_client, **kw):
    gw, url = await gateway_factory(**kw)
    client = await connect_client(url)
    ok = await client.recv()
    assert ok["type"] == "auth.ok", ok
    status = await client.recv()
    assert status["type"] == "agent.status" and "requestId" not in status
    return gw, client, ok


async def test_auth_ok_advertises_agent_and_capabilities(gateway_factory, connect_client):
    _, _, ok = await authed(gateway_factory, connect_client)
    p = ok["payload"]
    assert ok["v"] == 1 and p["session"].startswith("sess_")
    assert p["agent"]["name"] == "Echo"
    assert {"streaming", "cancellation", "fileSystem", "terminal", "serverMetrics", "logs"} <= set(p["capabilities"])
    assert "serviceControl" not in p["capabilities"]  # no services allow-listed


async def test_bad_token_is_rejected_and_rate_limited(gateway_factory, connect_client):
    _, url = await gateway_factory()
    for _ in range(3):
        c = await connect_client(url, token="wrong-token-xxxxxxxxxxxxxxxx")
        f = await c.recv()
        assert f["type"] == "auth.error" and f["payload"]["code"] == "auth_failed"
    c = await connect_client(url, hello=False)
    with pytest.raises(ConnectionClosed):
        await c.recv()  # closed immediately: too many failures


async def test_wrong_path_and_missing_hello_close(gateway_factory, connect_client):
    _, url = await gateway_factory()
    c = await connect_client(url.replace("/v1/agent", "/nope"), hello=False)
    with pytest.raises(ConnectionClosed):
        await c.recv()
    c2 = await connect_client(url, hello=False)
    await c2.send("ping")  # anything before auth.hello is rejected
    assert (await c2.recv())["type"] == "auth.error"
    with pytest.raises(ConnectionClosed):
        await c2.recv()


async def test_ping_pong(gateway_factory, connect_client):
    _, c, _ = await authed(gateway_factory, connect_client)
    await c.send("ping")
    assert (await c.recv())["type"] == "pong"


async def test_message_streams_and_completes_then_history_lists(gateway_factory, connect_client):
    gw, c, _ = await authed(gateway_factory, connect_client, adapter=EchoAdapter(delay=0))
    rid, cid = str(uuid.uuid4()), str(uuid.uuid4())
    await c.send("message.send", {"content": "use a tool please", "responseMessageId": str(uuid.uuid4())}, rid, cid)
    frames = await c.until_terminal(rid)
    types = [f["type"] for f in frames]
    assert types[0] == "request.accepted"
    assert types[-1] == "message.completed"
    assert "tool.started" in types and "tool.output" in types and "tool.finished" in types
    assert types.index("tool.started") < types.index("tool.finished")
    text = "".join(f["payload"]["text"] for f in frames if f["type"] == "message.delta")
    assert "use a tool please" in text
    assert all(f["conversationId"] == cid for f in frames)

    convs = await c.rpc("conversations.list")
    assert convs[0]["id"] == cid and convs[0]["title"].startswith("use a tool")


async def test_cancel_stops_request(gateway_factory, connect_client):
    _, c, _ = await authed(gateway_factory, connect_client, adapter=EchoAdapter(delay=0.2))
    rid, cid = str(uuid.uuid4()), str(uuid.uuid4())
    await c.send("message.send", {"content": "a long answer"}, rid, cid)
    await asyncio.sleep(0.3)
    await c.send("request.cancel", {}, rid)
    frames = await c.until_terminal(rid)
    assert frames[-1]["type"] == "error" and frames[-1]["payload"]["code"] == "cancelled"


async def test_same_conversation_cannot_run_twice(gateway_factory, connect_client):
    _, c, _ = await authed(gateway_factory, connect_client, adapter=EchoAdapter(delay=0.2))
    cid = str(uuid.uuid4())
    r1, r2 = str(uuid.uuid4()), str(uuid.uuid4())
    await c.send("message.send", {"content": "first"}, r1, cid)
    await asyncio.sleep(0.05)
    await c.send("message.send", {"content": "second"}, r2, cid)
    frames = await c.until_terminal(r2)
    assert frames[-1]["payload"]["code"] == "busy"


async def test_invalid_requests_are_errors_not_crashes(gateway_factory, connect_client):
    _, c, _ = await authed(gateway_factory, connect_client)
    await c.send("message.send", {"content": "x"}, "not-a-uuid", str(uuid.uuid4()))
    f = await c.recv()
    assert f["type"] == "error" and f["payload"]["code"] == "bad_request"
    await c.ws.send("{garbage")
    f = await c.recv()
    assert f["type"] == "error" and f["payload"]["code"] == "bad_frame"
    rid = str(uuid.uuid4())
    await c.send("message.send", {"content": ""}, rid, str(uuid.uuid4()))
    assert (await c.until_terminal(rid))[-1]["payload"]["code"] == "bad_request"
    assert (await c.rpc("no.such.method"))["error"]["code"] == "not_implemented"


def test_config_validation(tmp_path):
    base = {"auth": {"token_sha256": cfgmod.hash_token("x" * 40)}, "server": {"data_dir": str(tmp_path)}}
    assert cfgmod.from_dict(base).host == "127.0.0.1"
    with pytest.raises(ValueError):
        cfgmod.from_dict({**base, "auth": {"token_sha256": "short"}})
    with pytest.raises(ValueError, match="Refusing to bind"):
        cfgmod.from_dict({**base, "server": {"host": "0.0.0.0"}})
    assert cfgmod.from_dict({**base, "server": {"host": "100.101.1.2"}}).host == "100.101.1.2"
    with pytest.raises(ValueError):
        cfgmod.from_dict({**base, "system": {"file_roots": [{"path": "/"}]}})
    cfg = cfgmod.from_dict(base)
    assert cfg.token_matches("x" * 40) and not cfg.token_matches("y" * 40) and not cfg.token_matches("")
