"""Run-event relay: sequencing, resume without loss/duplicates, status fallback, isolation.

The fake Hermes below copies the semantics that make the relay necessary (hermes-agent
284d220, api_server_runs.py): one consumer per run, the queue is dropped when that consumer
disconnects (a second subscribe gets 404), ``: keepalive`` comments while idle, and pollable
``GET /v1/runs/{id}`` status with ``output`` once terminal.
"""
import asyncio
import json

import pytest
from aiohttp import web
from aiohttp.test_utils import TestServer

from brainbox_gateway import config as cfgmod
from brainbox_gateway import hermes_proxy as hp
from brainbox_gateway.run_relay import RelayLimits

from .test_hermes_proxy import ADMIN_TOKEN, DEVICE_TOKEN, HERMES_KEY, auth, make_cfg

OTHER_TOKEN = "other-device-token-abcdefghijklmnopqrstuv"


class FakeHermesRuns:
    def __init__(self):
        self.queues: dict[str, asyncio.Queue] = {}
        self.status: dict[str, dict] = {}
        self.subscriptions: dict[str, int] = {}
        self.counter = 0
        self.drop_stream_after: dict[str, int] = {}  # run -> close the SSE after N events (no terminal)

    def push(self, run_id, event: dict):
        event = {"run_id": run_id, "timestamp": 1.0, **event}
        q = self.queues.get(run_id)
        if q is not None:
            q.put_nowait(event)
        if event["event"].startswith("run.") and event["event"] != "run.steered":
            state = event["event"].split(".", 1)[1]
            self.status[run_id].update(status=state, output=event.get("output"), error=event.get("error"))

    def finish_silently(self, run_id, output):
        """Run ends server-side; nothing reaches a (dropped) stream."""
        self.status[run_id].update(status="completed", output=output, last_event="run.completed")

    def app(self):
        app = web.Application()

        async def runs(request):
            assert request.headers.get("Authorization") == f"Bearer {HERMES_KEY}"
            self.counter += 1
            run_id = f"run_{self.counter}"
            self.queues[run_id] = asyncio.Queue()
            self.status[run_id] = {"object": "hermes.run", "run_id": run_id, "status": "running"}
            return web.json_response({"run_id": run_id, "status": "started"}, status=202)

        async def events(request):
            run_id = request.match_info["run_id"]
            q = self.queues.get(run_id)
            if q is None:
                return web.json_response({"error": {"code": "run_not_found"}}, status=404)
            self.subscriptions[run_id] = self.subscriptions.get(run_id, 0) + 1
            resp = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
            await resp.prepare(request)
            sent = 0
            try:
                while True:
                    try:
                        event = await asyncio.wait_for(q.get(), timeout=0.2)
                    except asyncio.TimeoutError:
                        await resp.write(b": keepalive\n\n")
                        continue
                    await resp.write(f"data: {json.dumps(event)}\n\n".encode())
                    sent += 1
                    if event["event"] in ("run.completed", "run.failed", "run.cancelled"):
                        await resp.write(b": stream closed\n\n")
                        break
                    if self.drop_stream_after.get(run_id) == sent:
                        break
            finally:
                self.queues.pop(run_id, None)  # Hermes: _drop_run_transport on disconnect
            return resp

        async def status(request):
            run_id = request.match_info["run_id"]
            if run_id not in self.status:
                return web.json_response({"error": {"code": "run_not_found"}}, status=404)
            return web.json_response(self.status[run_id])

        async def stop(request):
            run_id = request.match_info["run_id"]
            self.status[run_id]["status"] = "stopping"
            return web.json_response({"run_id": run_id, "status": "stopping"})

        app.router.add_post("/v1/runs", runs)
        app.router.add_get("/v1/runs/{run_id}/events", events)
        app.router.add_get("/v1/runs/{run_id}", status)
        app.router.add_post("/v1/runs/{run_id}/stop", stop)
        return app


@pytest.fixture
async def hermes():
    fake = FakeHermesRuns()
    server = TestServer(fake.app())
    await server.start_server()
    yield fake, str(server.make_url("")).rstrip("/")
    await server.close()


@pytest.fixture
def relay_client(hermes, aiohttp_client, tmp_path):
    fake, url = hermes

    async def factory(limits: RelayLimits | None = None):
        cfg = make_cfg(tmp_path, url)
        cfg.devices.append(hp.Device(name="Other iPad", token_sha256=cfgmod.hash_token(OTHER_TOKEN)))
        proxy = hp.HermesProxy(cfg)
        if limits is not None:
            proxy.relay.limits = limits
        client = await aiohttp_client(proxy.app())
        return client, fake, proxy

    return factory


def parse_sse(text: str) -> list[dict]:
    frames = []
    for block in text.split("\n\n"):
        frame = {}
        for line in block.split("\n"):
            if line.startswith("id: "):
                frame["id"] = int(line[4:])
            elif line.startswith("event: "):
                frame["event_name"] = line[7:]
            elif line.startswith("data: "):
                frame["data"] = json.loads(line[6:])
        if "data" in frame:
            frames.append(frame)
    return frames


async def start_run(client):
    r = await client.post("/hermes/v1/runs", json={"input": "hi", "session_id": "ios_" + "a" * 32}, headers=auth())
    assert r.status == 202
    return (await r.json())["run_id"]


async def wait_for(predicate, timeout=5.0):
    deadline = asyncio.get_running_loop().time() + timeout
    while not predicate():
        if asyncio.get_running_loop().time() > deadline:
            raise AssertionError("condition not met in time")
        await asyncio.sleep(0.02)


async def test_events_are_sequenced_ordered_and_resumable_without_duplicates(relay_client):
    client, fake, proxy = await relay_client()
    run_id = await start_run(client)
    await wait_for(lambda: fake.subscriptions.get(run_id) == 1)
    for word in ["Hel", "lo", " world"]:
        fake.push(run_id, {"event": "message.delta", "delta": word})
    fake.push(run_id, {"event": "tool.started", "tool": "terminal", "preview": "ls"})
    fake.push(run_id, {"event": "run.completed", "output": "Hello world"})
    await wait_for(lambda: proxy.relay.get(run_id).finished)

    r = await client.get(f"/hermes/brainbox/runs/{run_id}/events", headers=auth())
    frames = parse_sse(await r.text())
    assert [f["id"] for f in frames if "id" in f] == sorted(f["id"] for f in frames if "id" in f)
    names = [f["data"]["event"] for f in frames]
    assert names == ["brainbox.upstream", "message.delta", "message.delta", "message.delta", "tool.started", "run.completed"]
    assert all(f["data"]["run_id"] == run_id for f in frames)

    # Resume after the 3rd frame: exactly the remaining events, nothing repeated.
    r = await client.get(f"/hermes/brainbox/runs/{run_id}/events?after=3", headers=auth())
    resumed = parse_sse(await r.text())
    assert [f["id"] for f in resumed] == [4, 5, 6]
    # Last-Event-ID works the same way (EventSource reconnects).
    r = await client.get(f"/hermes/brainbox/runs/{run_id}/events", headers={**auth(), "Last-Event-ID": "5"})
    assert [f["id"] for f in parse_sse(await r.text())] == [6]


async def test_phone_disconnect_loses_nothing_and_hermes_keeps_one_consumer(relay_client):
    client, fake, proxy = await relay_client()
    run_id = await start_run(client)
    await wait_for(lambda: fake.subscriptions.get(run_id) == 1)
    fake.push(run_id, {"event": "message.delta", "delta": "first "})

    # The phone reads a little, then its socket dies (backgrounded app).
    resp = await client.get(f"/hermes/brainbox/runs/{run_id}/events", headers=auth())
    seen = b""
    while b"first" not in seen:
        seen += await resp.content.readany()
    resp.close()

    # Hermes keeps producing while the phone is away.
    fake.push(run_id, {"event": "message.delta", "delta": "second "})
    fake.push(run_id, {"event": "message.delta", "delta": "third"})
    fake.push(run_id, {"event": "run.completed", "output": "first second third"})
    await wait_for(lambda: proxy.relay.get(run_id).finished)

    first = [f for f in parse_sse(seen.decode()) if "id" in f]
    cursor = first[-1]["id"]
    r = await client.get(f"/hermes/brainbox/runs/{run_id}/events?after={cursor}", headers=auth())
    later = parse_sse(await r.text())
    deltas = [f["data"]["delta"] for f in later if f["data"]["event"] == "message.delta"]
    assert deltas == ["second ", "third"]
    assert later[-1]["data"]["event"] == "run.completed"
    assert fake.subscriptions[run_id] == 1  # the relay was Hermes' only consumer throughout


async def test_legacy_events_route_is_served_by_the_relay(relay_client):
    client, fake, proxy = await relay_client()
    run_id = await start_run(client)
    await wait_for(lambda: fake.subscriptions.get(run_id) == 1)
    fake.push(run_id, {"event": "message.delta", "delta": "x"})
    fake.push(run_id, {"event": "run.completed", "output": "x"})
    r = await client.get(f"/hermes/v1/runs/{run_id}/events", headers=auth())
    frames = parse_sse(await r.text())
    assert frames[-1]["data"]["event"] == "run.completed"
    assert fake.subscriptions[run_id] == 1


async def test_lost_hermes_stream_falls_back_to_status_and_reports_it(relay_client):
    client, fake, proxy = await relay_client(RelayLimits(status_poll_seconds=0.05))
    run_id = await start_run(client)
    await wait_for(lambda: fake.subscriptions.get(run_id) == 1)
    fake.drop_stream_after[run_id] = 1
    fake.push(run_id, {"event": "message.delta", "delta": "partial"})
    await wait_for(lambda: proxy.relay.get(run_id).upstream == "polling")
    fake.finish_silently(run_id, "partial and the rest")
    await wait_for(lambda: proxy.relay.get(run_id).finished)

    r = await client.get(f"/hermes/brainbox/runs/{run_id}/events", headers=auth())
    frames = [f["data"] for f in parse_sse(await r.text())]
    upstream_states = [f["state"] for f in frames if f["event"] == "brainbox.upstream"]
    assert upstream_states == ["live", "polling"]
    final = frames[-1]
    assert final["event"] == "run.completed" and final["source"] == "status"
    assert final["output"] == "partial and the rest"


async def test_heartbeats_are_transport_only(relay_client):
    client, fake, proxy = await relay_client(RelayLimits(heartbeat_seconds=0.6))
    run_id = await start_run(client)
    await wait_for(lambda: fake.subscriptions.get(run_id) == 1)
    resp = await client.get(f"/hermes/brainbox/runs/{run_id}/events", headers=auth())
    buf = b""
    while b"brainbox.heartbeat" not in buf:
        buf += await resp.content.readany()
    resp.close()
    beats = [f for f in parse_sse(buf.decode()) if f["data"]["event"] == "brainbox.heartbeat"]
    assert beats and all("id" not in f for f in beats)  # never advances the resume cursor
    beat = beats[0]["data"]
    # Hermes hasn't sent a real event yet, and the heartbeat doesn't pretend otherwise.
    assert beat["upstream"] == "live" and beat["last_event_at"] is None
    assert beat["upstream_alive_at"] is not None  # Hermes' keepalives prove the link is up
    assert beat["last_seq"] == 1  # only the relay's "live" marker so far — no fake progress


async def test_other_devices_cannot_read_or_stop_a_run(relay_client):
    client, fake, proxy = await relay_client()
    run_id = await start_run(client)
    r = await client.get(f"/hermes/brainbox/runs/{run_id}/events", headers=auth(OTHER_TOKEN))
    assert r.status == 404
    r = await client.get(f"/hermes/v1/runs/{run_id}/events", headers=auth(OTHER_TOKEN))
    assert r.status == 404
    r = await client.post(f"/hermes/v1/runs/{run_id}/stop", json={}, headers=auth(OTHER_TOKEN))
    assert r.status == 404
    assert fake.status[run_id]["status"] == "running"
    r = await client.post(f"/hermes/v1/runs/{run_id}/stop", json={}, headers=auth())
    assert r.status == 200
    # Admin devices may see every run (Tasks screen on an admin phone).
    fake.push(run_id, {"event": "run.cancelled"})
    r = await client.get(f"/hermes/brainbox/runs/{run_id}/events", headers=auth(ADMIN_TOKEN))
    assert r.status == 200


async def test_parallel_runs_stay_isolated(relay_client):
    client, fake, proxy = await relay_client()
    a = await start_run(client)
    b = await start_run(client)
    await wait_for(lambda: fake.subscriptions.get(a) == 1 and fake.subscriptions.get(b) == 1)
    fake.push(a, {"event": "message.delta", "delta": "A"})
    fake.push(b, {"event": "message.delta", "delta": "B"})
    # A stale/foreign event on a's stream is dropped, never shown in a.
    fake.queues[a].put_nowait({"event": "message.delta", "delta": "LEAK", "run_id": b})
    fake.push(a, {"event": "run.cancelled"})
    fake.push(b, {"event": "run.completed", "output": "B"})
    await wait_for(lambda: proxy.relay.get(a).finished and proxy.relay.get(b).finished)
    ra = [f["data"] for f in parse_sse(await (await client.get(f"/hermes/brainbox/runs/{a}/events", headers=auth())).text())]
    rb = [f["data"] for f in parse_sse(await (await client.get(f"/hermes/brainbox/runs/{b}/events", headers=auth())).text())]
    assert [e.get("delta") for e in ra if e["event"] == "message.delta"] == ["A"]
    assert ra[-1]["event"] == "run.cancelled" and rb[-1]["event"] == "run.completed"
    assert all(e["run_id"] == a for e in ra) and all(e["run_id"] == b for e in rb)


async def test_evicted_events_arrive_as_a_snapshot(relay_client):
    client, fake, proxy = await relay_client(RelayLimits(max_events=3))
    run_id = await start_run(client)
    await wait_for(lambda: fake.subscriptions.get(run_id) == 1)
    for part in ["a", "b", "c", "d"]:
        fake.push(run_id, {"event": "message.delta", "delta": part})
    fake.push(run_id, {"event": "run.completed", "output": "abcd"})
    await wait_for(lambda: proxy.relay.get(run_id).finished)
    frames = [f["data"] for f in parse_sse(await (await client.get(f"/hermes/brainbox/runs/{run_id}/events", headers=auth())).text())]
    assert frames[0]["event"] == "brainbox.snapshot"
    text = frames[0]["text"] + "".join(f.get("delta", "") for f in frames[1:] if f["event"] == "message.delta")
    assert text == "abcd"


async def test_unrelayed_run_on_brainbox_route_says_so(relay_client):
    client, fake, proxy = await relay_client()
    r = await client.get("/hermes/brainbox/runs/run_999/events", headers=auth())
    assert r.status == 404
    assert (await r.json())["error"]["code"] == "run_not_relayed"


async def test_info_advertises_the_relay(relay_client):
    client, fake, proxy = await relay_client()
    info = await (await client.get("/hermes/brainbox/info", headers=auth())).json()
    assert info["features"]["run_relay"] is True
