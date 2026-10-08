"""Hermes adapters against FAKE Hermes installs (no real Hermes here).
These prove the gateway↔worker plumbing; real compatibility is confirmed
only by tools/probe_hermes.py on the VPS."""
import asyncio
import os
import sys
import textwrap
import uuid

import psutil

from brainbox_gateway.adapters import HermesCLIAdapter, HermesLibraryAdapter, RunContext
from brainbox_gateway.conversations import ConversationStore
from tests.conftest import make_config

FAKE_WITH_CALLBACKS = '''
import time
class AIAgent:
    def __init__(self, model="", quiet_mode=False, skip_memory=False, max_iterations=500,
                 stream_delta_callback=None, tool_progress_callback=None):
        assert quiet_mode is True
        self.stream = stream_delta_callback
        self.tool = tool_progress_callback
    def run_conversation(self, user_message, conversation_history=None, task_id=None):
        print("noise that must not corrupt the event stream")
        if user_message == "sleep":
            time.sleep(60)
        n = len(conversation_history or [])
        self.tool("terminal", "uptime")
        for part in ["Hello ", "from ", "fake ", "Hermes"]:
            self.stream(part)
        msgs = list(conversation_history or []) + [{"role": "user", "content": user_message}, {"role": "assistant", "content": f"history={n}"}]
        return {"final_response": "Hello from fake Hermes", "messages": msgs}
'''

FAKE_NO_CALLBACKS = '''
class AIAgent:
    def __init__(self, quiet_mode=False):
        pass
    def run_conversation(self, user_message, conversation_history=None):
        return {"final_response": "Plain final answer " * 5, "messages": None}
'''


def fake_install(tmp_path, source):
    d = tmp_path / "hermes-src"
    d.mkdir()
    (d / "run_agent.py").write_text(source)
    return d


def library_adapter(tmp_path, source, verified=True):
    cfg = make_config(tmp_path)
    src = fake_install(tmp_path, source)
    cfg.adapter = "hermes"
    cfg.hermes.source_dir = str(src)
    cfg.hermes.python = sys.executable
    cfg.hermes.hermes_home = str(tmp_path / "home")
    cfg.hermes.verified = verified
    return HermesLibraryAdapter(cfg)


async def run(adapter, content, history=None):
    events = []

    async def emit(kind, payload):
        events.append((kind, payload))

    result = await adapter.run(RunContext(str(uuid.uuid4()), content, history or [], emit))
    return events, result


async def test_unverified_adapter_refuses_to_run(tmp_path):
    adapter = library_adapter(tmp_path, FAKE_WITH_CALLBACKS, verified=False)
    try:
        await run(adapter, "hi")
        raise AssertionError("should refuse")
    except Exception as exc:
        assert getattr(exc, "code", "") == "not_implemented"


async def test_library_adapter_streams_tools_and_returns_history(tmp_path):
    adapter = library_adapter(tmp_path, FAKE_WITH_CALLBACKS)
    events, history = await run(adapter, "hi", history=[{"role": "user", "content": "a"}, {"role": "assistant", "content": "b"}])
    text = "".join(p["text"] for k, p in events if k == "delta")
    assert text == "Hello from fake Hermes"
    kinds = [k for k, _ in events]
    assert "tool.started" in kinds and "tool.finished" in kinds
    started = next(p for k, p in events if k == "tool.started")
    assert started["kind"] == "terminal" and started["name"] == "terminal"
    assert history[-1]["content"] == "history=2", "previous turns must be passed to Hermes"


async def test_library_adapter_without_callbacks_still_streams_final(tmp_path):
    adapter = library_adapter(tmp_path, FAKE_NO_CALLBACKS)
    events, history = await run(adapter, "hi")
    deltas = [p["text"] for k, p in events if k == "delta"]
    assert len(deltas) > 1 and "".join(deltas).startswith("Plain final answer")
    assert history[-1] == {"role": "assistant", "content": "".join(deltas)}


async def test_cancel_kills_only_the_worker(tmp_path):
    adapter = library_adapter(tmp_path, FAKE_WITH_CALLBACKS)
    before = {p.pid for p in psutil.Process().children(recursive=True)}
    task = asyncio.create_task(run(adapter, "sleep"))
    await asyncio.sleep(1.0)
    workers = [p for p in psutil.Process().children(recursive=True) if p.pid not in before]
    assert workers, "worker should be running"
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass
    await asyncio.sleep(0.3)
    assert all(not p.is_running() or p.status() == psutil.STATUS_ZOMBIE for p in workers)


async def test_cli_adapter_streams_stdout(tmp_path):
    cfg = make_config(tmp_path)
    fake = tmp_path / "hermes"
    fake.write_text(textwrap.dedent("""\
        #!/bin/sh
        # fake hermes: echo args so the test can check flags
        echo "args: $*"
        echo "answer line"
    """))
    os.chmod(fake, 0o755)
    cfg.hermes.mode = "cli"
    cfg.hermes.hermes_bin = str(fake)
    cfg.hermes.verified = True
    adapter = HermesCLIAdapter(cfg)
    events, history = await run(adapter, "status?", history=[{"role": "user", "content": "earlier"}])
    text = "".join(p["text"] for k, p in events if k == "delta")
    assert "chat -q" in text and "-Q" in text and "answer line" in text
    assert "--yolo" not in text, "dangerous commands are never auto-approved by default"
    assert "Earlier in this Brainbox conversation" in text
    assert history[-1]["role"] == "assistant"


def test_cli_command_flags(tmp_path):
    cfg = make_config(tmp_path)
    cfg.hermes.toolsets = ["terminal", "file"]
    cmd = HermesCLIAdapter(cfg).build_command("x")
    assert cmd[1:5] == ["chat", "-q", "x", "-Q"] and cmd[-2:] == ["-t", "terminal,file"]
    cfg.hermes.allow_dangerous_commands = True
    assert HermesCLIAdapter(cfg).build_command("x")[1] == "--yolo"


def test_conversation_store_roundtrip(tmp_path):
    store = ConversationStore(tmp_path)
    cid = str(uuid.uuid4())
    assert store.load(cid)["messages"] == []
    store.save(cid, [{"role": "user", "content": "x"}] * 500, title="T", preview="p")
    data = store.load(cid)
    assert len(data["messages"]) == 400 and data["title"] == "T"
    assert oct(os.stat(store.dir / f"{cid}.json").st_mode & 0o777) == "0o600"
    assert store.summaries()[0]["id"] == cid
