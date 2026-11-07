"""Contract tests against the REAL Hermes API server code (not a fake).

Runs Hermes' own ``APIServerAdapter`` run handlers (``/v1/runs``, ``/events``, status, stop)
from a Hermes checkout, with only the LLM agent replaced by a scripted stand-in that calls
the same callbacks the real ``AIAgent`` calls (``stream_delta_callback``,
``tool_progress_callback``). The Brainbox proxy sits in front exactly as on the VPS.

Set ``HERMES_SRC`` to a hermes-agent checkout (CI pins 284d220). Skipped otherwise.
"""
import asyncio
import json
import os
import sys
import threading
from unittest.mock import patch

import pytest

HERMES_SRC = os.environ.get("HERMES_SRC", "")
if not HERMES_SRC or not os.path.isdir(HERMES_SRC):
    pytest.skip("HERMES_SRC not set — real Hermes contract tests skipped", allow_module_level=True)
# Never touch a real ~/.hermes from tests.
os.environ["HERMES_HOME"] = os.environ.get("BRAINBOX_TEST_HERMES_HOME") or __import__("tempfile").mkdtemp(prefix="hermes-home-")
sys.path.insert(0, HERMES_SRC)
try:
    from gateway.config import PlatformConfig  # noqa: E402  (Hermes)
    from gateway.platforms.api_server import APIServerAdapter  # noqa: E402  (Hermes)
except Exception as exc:  # pragma: no cover
    pytest.skip(f"Hermes checkout not importable: {exc}", allow_module_level=True)

from aiohttp import web  # noqa: E402
from aiohttp.test_utils import TestServer  # noqa: E402

from brainbox_gateway import hermes_proxy as hp  # noqa: E402

from .test_hermes_proxy import HERMES_KEY, auth, make_cfg  # noqa: E402
from .test_run_relay import parse_sse, wait_for  # noqa: E402


class ScriptedAgent:
    """Stands in for AIAgent: the run is driven step by step from the test."""

    def __init__(self, delta_cb, progress_cb):
        self.delta_cb = delta_cb
        self.progress_cb = progress_cb
        self.steps: "queue.Queue" = __import__("queue").Queue()
        self.interrupted = threading.Event()
        self.session_prompt_tokens = 3
        self.session_completion_tokens = 4
        self.session_total_tokens = 7

    def interrupt(self, message=None):
        self.interrupted.set()
        self.steps.put(("stop", None))

    def run_conversation(self, user_message=None, conversation_history=None, task_id=None, **_):
        text = ""
        while True:
            kind, value = self.steps.get(timeout=20)
            if kind == "delta":
                text += value
                self.delta_cb(value)
            elif kind == "tool":
                self.progress_cb("tool.started", value, "preview")
            elif kind == "tool_done":
                self.progress_cb("tool.completed", value, None, duration=0.5, is_error=False)
            elif kind == "finish":
                return {"final_response": value if value is not None else text}
            elif kind == "stop":
                return {"final_response": text, "interrupted": True}


class RealHermes:
    def __init__(self):
        self.adapter = APIServerAdapter(PlatformConfig(enabled=True, extra={"key": HERMES_KEY}))
        self.agents: list[ScriptedAgent] = []
        self.created = threading.Event()

    def create_agent(self, *args, stream_delta_callback=None, tool_progress_callback=None, **kwargs):
        agent = ScriptedAgent(stream_delta_callback, tool_progress_callback)
        self.agents.append(agent)
        return agent

    def app(self):
        a = self.adapter
        app = web.Application()
        app["api_server_adapter"] = a
        app.router.add_post("/v1/runs", a._handle_runs)
        app.router.add_get("/v1/runs/{run_id}", a._handle_get_run)
        app.router.add_get("/v1/runs/{run_id}/events", a._handle_run_events)
        app.router.add_post("/v1/runs/{run_id}/stop", a._handle_stop_run)
        app.router.add_post("/v1/runs/{run_id}/steer", a._handle_steer_run)
        return app


@pytest.fixture
async def real_hermes():
    hermes = RealHermes()
    with patch.object(hermes.adapter, "_create_agent", side_effect=hermes.create_agent), \
            patch.object(hermes.adapter, "_conversation_history_for_session", return_value=[], create=True):
        server = TestServer(hermes.app())
        await server.start_server()
        yield hermes, str(server.make_url("")).rstrip("/")
        await server.close()


@pytest.fixture
def proxy_client(real_hermes, aiohttp_client, tmp_path):
    hermes, url = real_hermes

    async def factory():
        proxy = hp.HermesProxy(make_cfg(tmp_path, url))
        client = await aiohttp_client(proxy.app())
        return client, hermes, proxy

    return factory


async def agent_ready(hermes, index=0):
    await wait_for(lambda: len(hermes.agents) > index)
    return hermes.agents[index]


def hermes_resumes_streams() -> bool:
    """Newer Hermes keeps a per-run backlog and honours Last-Event-ID (`_RunStream`); 284d220 doesn't."""
    import gateway.platforms.api_server_runs as runs  # Hermes
    return hasattr(runs, "_RunStream")


async def test_disconnect_behaviour_of_this_hermes_version(real_hermes, aiohttp_client):
    """284d220: the root cause, shown on Hermes' own code — a dropped consumer loses the run's
    events (re-subscribe → 404). Newer Hermes: it resumes from Last-Event-ID. The app and the
    relay handle both."""
    hermes, url = real_hermes
    from aiohttp import ClientSession
    headers = {"Authorization": f"Bearer {HERMES_KEY}"}
    async with ClientSession() as http:
        r = await http.post(f"{url}/v1/runs", json={"input": "hi"}, headers=headers)
        run_id = (await r.json())["run_id"]
        agent = await agent_ready(hermes)
        resp = await http.get(f"{url}/v1/runs/{run_id}/events", headers=headers)
        agent.steps.put(("delta", "first"))
        buf = b""
        while b"first" not in buf:
            buf += await resp.content.readany()
        resp.close()  # the phone's socket dies
        await asyncio.sleep(0.3)
        agent.steps.put(("delta", " second"))
        seen = [f for f in parse_sse(buf.decode()) if "id" in f]
        resume_headers = dict(headers)
        if seen:
            resume_headers["Last-Event-ID"] = str(seen[-1]["id"])
        r2 = await http.get(f"{url}/v1/runs/{run_id}/events", headers=resume_headers)
        if hermes_resumes_streams():
            assert r2.status == 200
            agent.steps.put(("finish", None))
            later = [f["data"] for f in parse_sse(await r2.text())]
            assert [e.get("delta") for e in later if e["event"] == "message.delta"] == [" second"]
        else:
            assert r2.status == 404  # Hermes deleted the queue: " second" is gone for SSE
            agent.steps.put(("finish", None))
        for _ in range(50):
            status = await (await http.get(f"{url}/v1/runs/{run_id}", headers=headers)).json()
            if status["status"] == "completed":
                break
            await asyncio.sleep(0.05)
        assert status["output"] == "first second"


async def test_through_the_relay_a_disconnect_loses_no_tokens(proxy_client):
    client, hermes, proxy = await proxy_client()
    r = await client.post("/hermes/v1/runs", json={"input": "hi", "session_id": "ios_" + "b" * 32}, headers=auth())
    assert r.status == 202
    run_id = (await r.json())["run_id"]
    agent = await agent_ready(hermes)
    agent.steps.put(("delta", "Hello"))

    resp = await client.get(f"/hermes/brainbox/runs/{run_id}/events", headers=auth())
    buf = b""
    while b"Hello" not in buf:
        buf += await resp.content.readany()
    resp.close()
    cursor = [f for f in parse_sse(buf.decode()) if "id" in f][-1]["id"]

    agent.steps.put(("tool", "terminal"))
    agent.steps.put(("tool_done", "terminal"))
    agent.steps.put(("delta", " world"))
    agent.steps.put(("finish", None))
    await wait_for(lambda: proxy.relay.get(run_id).finished)

    later = [f["data"] for f in parse_sse((await (await client.get(
        f"/hermes/brainbox/runs/{run_id}/events?after={cursor}", headers=auth())).text()))]
    names = [e["event"] for e in later]
    assert names == ["tool.started", "tool.completed", "message.delta", "run.completed"]
    assert later[2]["delta"] == " world"
    assert later[-1]["output"] == "Hello world"
    assert later[-1]["usage"]["total_tokens"] == 7
    assert all(e["run_id"] == run_id for e in later)


async def test_stopping_one_run_leaves_a_parallel_run_running(proxy_client):
    client, hermes, proxy = await proxy_client()
    ids = []
    for letter in "cd":
        r = await client.post("/hermes/v1/runs", json={"input": letter, "session_id": "ios_" + letter * 32}, headers=auth())
        ids.append((await r.json())["run_id"])
    a, b = await agent_ready(hermes, 0), await agent_ready(hermes, 1)
    a.steps.put(("delta", "A"))
    b.steps.put(("delta", "B"))
    r = await client.post(f"/hermes/v1/runs/{ids[0]}/stop", json={}, headers=auth())
    assert (await r.json())["status"] == "stopping"
    await wait_for(lambda: proxy.relay.get(ids[0]).finished)
    assert a.interrupted.is_set() and not b.interrupted.is_set()
    assert not proxy.relay.get(ids[1]).finished
    b.steps.put(("finish", None))
    await wait_for(lambda: proxy.relay.get(ids[1]).finished)
    first = [f["data"]["event"] for f in parse_sse(await (await client.get(f"/hermes/brainbox/runs/{ids[0]}/events", headers=auth())).text())]
    second = [f["data"] for f in parse_sse(await (await client.get(f"/hermes/brainbox/runs/{ids[1]}/events", headers=auth())).text())]
    assert first[-1] == "run.cancelled"
    assert second[-1]["event"] == "run.completed" and second[-1]["output"] == "B"


async def test_run_event_wire_shape_matches_what_the_app_parses(proxy_client):
    """Field names the iOS parser relies on, produced by Hermes itself."""
    client, hermes, proxy = await proxy_client()
    r = await client.post("/hermes/v1/runs", json={"input": "x", "session_id": "ios_" + "e" * 32}, headers=auth())
    run_id = (await r.json())["run_id"]
    agent = await agent_ready(hermes)
    for step in [("delta", "d"), ("tool", "web_search"), ("tool_done", "web_search"), ("finish", "final")]:
        agent.steps.put(step)
    await wait_for(lambda: proxy.relay.get(run_id).finished)
    frames = {f["data"]["event"]: f["data"] for f in parse_sse(await (await client.get(
        f"/hermes/brainbox/runs/{run_id}/events", headers=auth())).text())}
    assert set(frames["message.delta"]) >= {"event", "run_id", "timestamp", "delta", "seq"}
    assert set(frames["tool.started"]) >= {"tool", "preview"}
    assert set(frames["tool.completed"]) >= {"tool", "duration", "error"}
    assert frames["run.completed"]["output"] == "final"


# --------------------------------------------------------------------------- command helper on real Hermes

@pytest.fixture
def real_catalog(tmp_path):
    from brainbox_gateway.commands import CommandCatalog
    home = tmp_path / "hermes-home"
    home.mkdir()
    (home / "config.yaml").write_text("agent:\n  system_prompt: You are the test persona.\n")
    catalog = CommandCatalog("/nonexistent/bin/hermes", str(home), timeout=120)
    catalog.python = sys.executable
    catalog.source_dir = HERMES_SRC
    return catalog


async def test_real_registry_exposes_args_aliases_and_busy_policy(real_catalog):
    data = await real_catalog.catalog()
    by_name = {c["name"]: c for c in data["native"]}
    for name in ("help", "status", "model", "stop", "new", "queue", "steer", "bg", "btw"):
        assert name in by_name, name
    assert "q" in by_name["queue"]["aliases"] and by_name["queue"]["args_hint"]
    assert by_name["help"]["executor"] is True and by_name["status"]["executor"] is False
    assert by_name["steer"]["busy_policy"] == "dispatch"


async def test_real_help_and_version_executors_run(real_catalog):
    help_text = await real_catalog.execute("help", "")
    assert help_text.get("text") and "/help" in help_text["text"] or "help" in help_text["text"].lower()
    version = await real_catalog.execute("version", "")
    assert version.get("text")


async def test_real_gateway_prompt_matches_what_telegram_uses(real_catalog):
    assert await real_catalog.persona_prompt() == "You are the test persona."
    report = await real_catalog.parity()
    assert report["persona_prompt_chars"] == len("You are the test persona.")
    assert isinstance(report["toolsets"]["telegram"], list) and isinstance(report["toolsets"]["api_server"], list)
    assert report["busy_input_mode"] in {"interrupt", "queue", "steer"}
    assert not report.get("unavailable"), report.get("unavailable")
