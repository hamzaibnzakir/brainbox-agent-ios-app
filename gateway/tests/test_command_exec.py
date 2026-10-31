"""Hermes commands run by Hermes' own code, /btw ownership, parity report, gateway prompt."""
import json
import os
import sys

import pytest

from brainbox_gateway.commands import CommandCatalog

from .test_hermes_proxy import ADMIN_TOKEN, auth, make_client, upstream  # noqa: F401  (fixtures)

STUBS = {
    "hermes_cli/__init__.py": "",
    "agent/__init__.py": "",
    "gateway/__init__.py": "",
    "hermes_cli/commands.py": '''
from dataclasses import dataclass
@dataclass(frozen=True)
class CommandDef:
    name: str
    description: str
    category: str
    aliases: tuple = ()
    args_hint: str = ""
    subcommands: tuple = ()
    cli_only: bool = False
    gateway_only: bool = False
    busy_policy: str = "reject"
    execute: str = None
COMMAND_REGISTRY = [
    CommandDef("help", "Show commands", "Info", (), "[skills|<filter>]", busy_policy="dispatch", execute="gateway_help"),
    CommandDef("version", "Show version", "Info", ("v",), busy_policy="dispatch", execute="version"),
    CommandDef("compress", "Compress context", "Session"),
    CommandDef("btw", "Side question", "Session", (), "<question>", busy_policy="dispatch"),
]
''',
    "hermes_cli/slash_exec.py": '''
from dataclasses import dataclass, field
@dataclass(frozen=True)
class CommandContext:
    surface: str = "cli"
    args: str = ""
    options: dict = field(default_factory=dict)
@dataclass(frozen=True)
class Reply:
    text: str
    format: str = "plain"
def execute_command(name, ctx):
    if name == "help":
        return Reply(f"help via {ctx.surface} args={ctx.args!r}", "markdown")
    if name == "version":
        return Reply("Hermes v9")
    raise LookupError(name)
''',
    "agent/skill_commands.py": '''
def get_skill_commands():
    return {}
''',
    "hermes_state.py": '''
import json, os
class SessionDB:
    def __init__(self, read_only=False):
        assert read_only, "the helper must open the DB read-only"
    def get_messages_as_conversation(self, sid):
        return [] if sid.endswith("0" * 32) else [{"role": "user", "content": "earlier " + sid}]
''',
    "agent/side_question.py": '''
def answer_side_question(question, history, parent_agent=None, main_runtime=None):
    return f"answer to {question} using {history[0]['content']} model={main_runtime['model']}"
''',
    "gateway/run.py": '''
import os
def _resolve_runtime_agent_kwargs():
    return {"model": "test-model", "provider": "x", "api_key": "k"}
def _resolve_gateway_model():
    return "test-model"
def _load_gateway_config():
    return {"platform_toolsets": {"telegram": ["web"]}}
class GatewayRunner:
    @staticmethod
    def _load_ephemeral_system_prompt():
        return os.environ.get("STUB_PERSONA", "You are Kat, David's agent.")
    @staticmethod
    def _load_provider_routing():
        return {}
    @staticmethod
    def _load_prefill_messages():
        return []
    @staticmethod
    def _load_fallback_model():
        return ["b"]
    @staticmethod
    def _load_busy_input_mode():
        return "queue"
''',
    "hermes_cli/tools_config.py": '''
def _get_platform_tools(cfg, platform):
    return {"web", "terminal", "send_message"} if platform == "telegram" else {"web", "terminal"}
''',
}


@pytest.fixture
def stub_hermes(tmp_path):
    src = tmp_path / "hermes-src"
    for rel, text in STUBS.items():
        path = src / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    bindir = src / "venv" / "bin"
    bindir.mkdir(parents=True)
    os.symlink(os.path.realpath(sys.executable), bindir / "python")
    (bindir / "hermes").write_text("#!/bin/sh\n")
    return str(bindir / "hermes")


@pytest.fixture
def stubbed(make_client, stub_hermes, tmp_path):  # noqa: F811
    async def factory(**overrides):
        client, fake, cfg = await make_client(**overrides)
        # The proxy instance is reachable through the bound handler of any route.
        handler = next(r.handler for r in client.server.app.router.routes() if getattr(r.handler, "__self__", None))
        proxy = handler.__self__
        proxy.commands = CommandCatalog(stub_hermes, str(tmp_path / "hermes-home"))
        return client, fake, proxy

    return factory


async def test_executor_commands_run_through_hermes_code(stubbed):
    client, _fake, _proxy = await stubbed()
    r = await client.post("/hermes/brainbox/commands/run", json={"name": "help", "args": "skills"}, headers=auth())
    assert r.status == 200, await r.text()
    body = await r.json()
    assert body == {"name": "help", "text": "help via gateway args='skills'", "format": "markdown", "source": "hermes"}
    r = await client.post("/hermes/brainbox/commands/run", json={"name": "v"}, headers=auth())  # alias
    assert (await r.json())["text"] == "Hermes v9"


async def test_non_executable_and_unknown_commands_are_refused_not_prompted(stubbed):
    client, fake, _proxy = await stubbed()
    before = len(fake.seen)
    r = await client.post("/hermes/brainbox/commands/run", json={"name": "compress"}, headers=auth())
    assert r.status == 409 and (await r.json())["error"]["code"] == "command_not_executable"
    r = await client.post("/hermes/brainbox/commands/run", json={"name": "nosuch"}, headers=auth())
    assert r.status == 404 and (await r.json())["error"]["code"] == "unknown_command"
    assert len(fake.seen) == before, "nothing reached Hermes' model endpoints"


async def test_btw_answers_from_the_owned_transcript_only(stubbed):
    client, _fake, proxy = await stubbed()
    sid = "ios_" + "a" * 32
    proxy.owners.record(sid, "someone-else-device")
    r = await client.post("/hermes/brainbox/commands/run", json={"name": "btw", "args": "why?", "session_id": sid},
                          headers=auth())
    assert r.status == 403
    mine = "ios_" + "b" * 32
    r = await client.post("/hermes/brainbox/commands/run", json={"name": "btw", "args": "why?", "session_id": mine},
                          headers=auth())
    assert r.status == 200, await r.text()
    assert (await r.json())["text"] == f"answer to why? using earlier {mine} model=test-model"
    r = await client.post("/hermes/brainbox/commands/run", json={"name": "btw", "args": "x", "session_id": "telegram_1"},
                          headers=auth())
    assert r.status == 400
    empty = "ios_" + "0" * 32
    r = await client.post("/hermes/brainbox/commands/run", json={"name": "btw", "args": "x", "session_id": empty},
                          headers=auth())
    assert "no conversation" in (await r.json())["text"]


async def test_parity_report_names_the_differences(stubbed):
    client, _fake, _proxy = await stubbed()
    r = await client.get("/hermes/brainbox/parity", headers=auth())
    assert r.status == 200, await r.text()
    report = await r.json()
    assert report["toolsets"]["only_telegram"] == ["send_message"]
    assert report["toolsets"]["explicit_telegram"] is True and report["toolsets"]["explicit_api_server"] is False
    assert report["persona_prompt_chars"] > 0 and "Kat" not in json.dumps(report), "prompt text never leaves the server"
    assert report["fallback_chain"] == 1 and report["gateway_prompt_applied"] is True
    assert report["busy_input_mode"] == "queue"


async def test_runs_get_telegrams_gateway_prompt_before_app_instructions(stubbed):
    client, fake, _proxy = await stubbed()
    r = await client.post("/hermes/v1/runs", json={"input": "hi", "session_id": "ios_" + "c" * 32,
                                                   "instructions": "Client renders Markdown."}, headers=auth())
    assert r.status == 202
    sent = json.loads(next(s for s in reversed(fake.seen) if s["path"] == "/v1/runs")["body"])
    assert sent["instructions"] == "You are Kat, David's agent.\n\nClient renders Markdown."
    assert sent["input"] == "hi"


async def test_gateway_prompt_can_be_turned_off(stubbed):
    client, fake, _proxy = await stubbed(parity__gateway_prompt=False)
    await client.post("/hermes/v1/runs", json={"input": "hi", "session_id": "ios_" + "d" * 32}, headers=auth())
    sent = json.loads(next(s for s in reversed(fake.seen) if s["path"] == "/v1/runs")["body"])
    assert "instructions" not in sent
