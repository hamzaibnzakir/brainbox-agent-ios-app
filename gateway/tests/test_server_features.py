"""Workspace files, direct terminal, push notifications and the server overview.

Everything runs against a fake Hermes and temporary folders; no real server, APNs or
production credential is involved."""
import asyncio
import getpass
import json
import os
import pwd
import time

import pytest
from aiohttp import web
from aiohttp.test_utils import TestServer

from brainbox_gateway import config as cfgmod
from brainbox_gateway import hermes_proxy as hp
from brainbox_gateway.push import (DEFAULT_PREFS, Notification, PushConfig, PushService, TokenRegistry, provider_jwt)
from brainbox_gateway.pty_terminal import TerminalConfig, parse_client_frame
from brainbox_gateway.workspace_files import Workspace, WorkspaceConfig, WorkspaceError, safe_name

TOKEN_A = "device-a-token-abcdefghijklmnopqrstuvwxyz"
TOKEN_B = "device-b-token-abcdefghijklmnopqrstuvwxyz"
HERMES_KEY = "server-side-hermes-key-0123456789abcdef"
APNS_TOKEN = "a" * 64


def terminal_user() -> str | None:
    """A non-root account the test can run shells as (the proxy refuses root)."""
    if os.geteuid() != 0:
        return getpass.getuser()
    try:
        pwd.getpwnam("nobody")
        return "nobody"
    except KeyError:
        return None


class FakeHermes:
    def __init__(self):
        self.jobs = []
        self.runs = {}
        self.healthy = True

    def app(self):
        app = web.Application()

        async def health(_):
            return web.json_response({"status": "ok"}) if self.healthy else web.json_response({}, status=503)

        async def jobs(_):
            return web.json_response({"jobs": self.jobs})

        async def run_status(request):
            run = self.runs.get(request.match_info["rid"])
            return web.json_response(run) if run else web.json_response({"error": "not found"}, status=404)

        async def create_run(request):
            return web.json_response({"run_id": "run_123", "status": "queued"}, status=202)

        app.router.add_get("/health", health)
        app.router.add_get("/api/jobs", jobs)
        app.router.add_get("/v1/runs/{rid}", run_status)
        app.router.add_post("/v1/runs", create_run)
        return app


@pytest.fixture
async def setup(aiohttp_client, tmp_path):
    fake = FakeHermes()
    server = TestServer(fake.app())
    await server.start_server()
    env = tmp_path / "hermes.env"
    env.write_text(f"API_SERVER_KEY={HERMES_KEY}\n")
    user = terminal_user()
    cfg = hp.config_from_dict({
        "proxy": {"hermes_url": str(server.make_url("")).rstrip("/"), "hermes_env_file": str(env),
                  "audit_log": str(tmp_path / "audit.log"), "state_dir": str(tmp_path / "state"),
                  "max_requests_per_minute": 1000},
        "files": {"root": str(tmp_path / "workspace"), "max_upload_bytes": 1000},
        "terminal": {"enabled": user is not None, "user": user or "", "shell": "/bin/sh", "cwd": str(tmp_path)},
        "devices": [{"name": "Phone A", "token_sha256": cfgmod.hash_token(TOKEN_A), "terminal": True},
                    {"name": "Phone B", "token_sha256": cfgmod.hash_token(TOKEN_B)}],
        "profiles": {"hermes_home": str(tmp_path / "hermes")},
    })
    proxy = hp.HermesProxy(cfg)
    client = await aiohttp_client(proxy.app())
    yield client, fake, proxy, cfg, tmp_path
    await server.close()


def auth(token=TOKEN_A):
    return {"Authorization": f"Bearer {token}"}


# --------------------------------------------------------------------------- files

def test_safe_name():
    assert safe_name("../../etc/passwd") == "passwd"
    assert safe_name("C:\\Users\\me\\photo.JPG") == "photo.JPG"
    assert safe_name(".bashrc") == "bashrc"
    assert safe_name("rm -rf $(whoami);.txt") == "rm -rf _(whoami)_.txt"
    assert safe_name("a\x00b\nc.png") == "abc.png"
    assert len(safe_name("x" * 300 + ".pdf")) <= 120 and safe_name("x" * 300 + ".pdf").endswith(".pdf")
    for bad in ("", "..", "/", "...."):
        with pytest.raises(WorkspaceError):
            safe_name(bad)


def test_workspace_refuses_traversal_and_symlinks(tmp_path):
    ws = Workspace(WorkspaceConfig(root=str(tmp_path / "ws")))
    ws.ensure()
    (tmp_path / "secret.txt").write_text("server secret")
    os.symlink(tmp_path / "secret.txt", tmp_path / "ws" / "outbox" / "link.txt")
    os.symlink(tmp_path, tmp_path / "ws" / "inbox" / "escape")
    for bad in ("/etc/passwd", "../secret.txt", "inbox/../../secret.txt", "inbox/./x", "etc/passwd", "inbox\\..\\x",
                "inbox/.hidden", "outbox/link.txt", "inbox/escape/secret.txt", "inbox/a\x00b"):
        with pytest.raises(WorkspaceError):
            ws.file_for_download(bad)
    listed = [e["name"] for e in ws.list("outbox")]
    assert "link.txt" not in listed, "symlinks are never listed"


async def test_upload_list_download_delete(setup):
    client, _fake, proxy, cfg, tmp_path = setup
    r = await client.get("/hermes/brainbox/files", headers=auth())
    assert r.status == 200
    assert [e["name"] for e in (await r.json())["data"]] == ["inbox", "outbox"]

    r = await client.post("/hermes/brainbox/files/upload?area=inbox&name=../../notes.txt", data=b"hello", headers=auth())
    assert r.status == 201, await r.text()
    uploaded = await r.json()
    entry = uploaded["file"]
    assert entry["path"] == "inbox/notes.txt" and entry["size"] == 5
    assert uploaded["absolute_path"] == str(tmp_path / "workspace" / "inbox" / "notes.txt")
    # Same name again never overwrites.
    r = await client.post("/hermes/brainbox/files/upload?area=inbox&name=notes.txt", data=b"again", headers=auth())
    assert (await r.json())["file"]["path"] == "inbox/notes (2).txt"
    assert (tmp_path / "workspace" / "inbox" / "notes.txt").read_bytes() == b"hello"

    r = await client.get("/hermes/brainbox/files/download?path=inbox/notes.txt", headers=auth())
    assert r.status == 200 and await r.read() == b"hello"
    assert "attachment" in r.headers["Content-Disposition"]

    r = await client.delete("/hermes/brainbox/files?path=inbox/notes.txt", headers=auth())
    assert r.status == 200
    assert not (tmp_path / "workspace" / "inbox" / "notes.txt").exists()
    audit = (tmp_path / "audit.log").read_text()
    assert "hello" not in audit and "files.upload" in audit


async def test_upload_limits_and_types(setup):
    client, *_rest, tmp_path = setup
    r = await client.post("/hermes/brainbox/files/upload?area=inbox&name=big.txt", data=b"x" * 1001, headers=auth())
    assert r.status == 413
    r = await client.post("/hermes/brainbox/files/upload?area=inbox&name=tool.exe", data=b"MZ", headers=auth())
    assert r.status == 415
    r = await client.post("/hermes/brainbox/files/upload?area=outbox&name=x.txt", data=b"x", headers=auth())
    assert r.status == 400
    r = await client.post("/hermes/brainbox/files/upload?area=inbox&name=empty.txt", data=b"", headers=auth())
    assert r.status == 400
    leftovers = [p.name for p in (tmp_path / "workspace" / "inbox").iterdir()]
    assert leftovers == [], f"no partial files left behind: {leftovers}"
    r = await client.get("/hermes/brainbox/files/download?path=../hermes.env", headers=auth())
    assert r.status == 400
    r = await client.get("/hermes/brainbox/files", headers={"Authorization": "Bearer nope"})
    assert r.status == 401


# --------------------------------------------------------------------------- system

async def test_system_overview_is_real_and_read_only(setup):
    client, fake, *_ = setup
    r = await client.get("/hermes/brainbox/system", headers=auth())
    body = await r.json()
    assert r.status == 200
    assert body["hermes"]["reachable"] is True and body["hermes"]["status"] == "ok"
    assert body["host"]["cpu_count"] == os.cpu_count()
    assert body["host"]["disks"][0]["path"] == "/"
    assert HERMES_KEY not in json.dumps(body)
    fake.healthy = False
    body = await (await client.get("/hermes/brainbox/system", headers=auth())).json()
    assert body["hermes"]["reachable"] is False and body["hermes"]["latency_ms"] is None


async def test_info_reports_features_per_device(setup):
    client, *_ = setup
    a = (await (await client.get("/hermes/brainbox/info", headers=auth())).json())["features"]
    b = (await (await client.get("/hermes/brainbox/info", headers=auth(TOKEN_B))).json())["features"]
    assert a["files"] and a["push"] == {"enabled": False, "ready": False}
    assert b["terminal"] is False


# --------------------------------------------------------------------------- terminal

def test_terminal_config_validation():
    with pytest.raises(ValueError):
        TerminalConfig.from_dict({"enabled": True, "user": "root"})
    with pytest.raises(ValueError):
        TerminalConfig.from_dict({"enabled": True, "user": ""})
    assert TerminalConfig.from_dict({}).enabled is False
    assert parse_client_frame('{"type":"resize","cols":5,"rows":2}') is None
    assert parse_client_frame('{"type":"exec","cmd":"x"}') is None
    assert parse_client_frame('{"type":"input","data":"ls\\r"}') == {"type": "input", "data": "ls\r"}


async def test_terminal_refused_without_permission(setup):
    client, *_ = setup
    r = await client.get("/hermes/brainbox/terminal/status", headers=auth(TOKEN_B))
    assert (await r.json())["available"] is False
    r = await client.get("/hermes/brainbox/terminal", headers=auth(TOKEN_B))
    assert r.status == 403
    r = await client.get("/hermes/brainbox/terminal")
    assert r.status == 401


async def _read_until(ws, predicate, timeout=10):
    collected = ""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        msg = await ws.receive(timeout=deadline - time.monotonic())
        if msg.type != web.WSMsgType.TEXT:
            break
        frame = json.loads(msg.data)
        if frame["type"] == "output":
            collected += frame["data"]
        if predicate(frame, collected):
            return frame, collected
    raise AssertionError(f"timed out; output so far: {collected!r}")


@pytest.mark.skipif(terminal_user() is None, reason="no non-root account to run a shell as")
async def test_interactive_pty_resize_interrupt_reattach(setup):
    client, _fake, proxy, cfg, tmp_path = setup
    ws = await client.ws_connect("/hermes/brainbox/terminal?cols=100&rows=30", headers=auth())
    ready = json.loads((await ws.receive(timeout=10)).data)
    assert ready["type"] == "ready" and ready["user"] == cfg.terminal.user and ready["cols"] == 100
    session_id = ready["session"]

    # A real TTY: stty reports the size we set, and the env has no proxy secrets.
    # Markers are computed by the shell ($((n+1))) so the echoed input never matches.
    await ws.send_json({"type": "input", "data": "stty size; echo TTY=$(tty | cut -c1-8); echo KEY=${API_SERVER_KEY:-none}; echo M_$((0+1))\n"})
    _, out = await _read_until(ws, lambda f, o: "M_1" in o)
    assert "30 100" in out and "TTY=/dev/pts" in out and "KEY=none" in out
    await ws.send_json({"type": "resize", "cols": 120, "rows": 40})
    await ws.send_json({"type": "input", "data": "stty size; echo M_$((1+1))\n"})
    _, out = await _read_until(ws, lambda f, o: "M_2" in o)
    assert "40 120" in out

    # Ctrl-C stops a running command but keeps the shell.
    await ws.send_json({"type": "input", "data": "sleep 30; echo NOT_$((0+7))\n"})
    await asyncio.sleep(0.5)
    await ws.send_json({"type": "interrupt"})
    await ws.send_json({"type": "input", "data": "echo M_$((2+1))\n"})
    _, out = await _read_until(ws, lambda f, o: "M_3" in o, timeout=8)
    assert "NOT_7" not in out

    # Drop the connection: the session survives and replays its scrollback.
    await ws.send_json({"type": "input", "data": "echo DROP_$((3+1))\n"})
    await _read_until(ws, lambda f, o: "DROP_4" in o)
    await ws.close()
    await asyncio.sleep(0.2)
    assert proxy.terminals.sessions[session_id].alive
    ws2 = await client.ws_connect(f"/hermes/brainbox/terminal?session={session_id}&cols=80&rows=24", headers=auth())
    ready2 = json.loads((await ws2.receive(timeout=10)).data)
    assert ready2["reattached"] is True and ready2["session"] == session_id
    await _read_until(ws2, lambda f, o: "DROP_4" in o)
    # Another device can't take it over.
    r = await client.get(f"/hermes/brainbox/terminal?session={session_id}", headers=auth(TOKEN_B))
    assert r.status == 403

    await ws2.send_json({"type": "input", "data": "exit\n"})
    frame, _ = await _read_until(ws2, lambda f, o: f["type"] == "exit")
    assert frame["code"] == 0
    await ws2.close()
    audit = (tmp_path / "audit.log").read_text()
    assert "stty" not in audit and "DROP_" not in audit, "keystrokes and output are never logged"


# --------------------------------------------------------------------------- push

def test_push_config_problems_never_leak_secrets(tmp_path):
    assert PushConfig().problems() == ["Push notifications are turned off on the server ([push] enabled = false)."]
    cfg = PushConfig(enabled=True, team_id="ABCDE12345", key_id="KEY1234567", key_file=str(tmp_path / "missing.p8"),
                     bundle_id="com.example.brainbox")
    assert any("key_file" in p for p in cfg.problems())
    with pytest.raises(ValueError):
        PushConfig.from_dict({"environment": "staging"})


def test_provider_jwt_is_valid_es256():
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
    import base64

    key = ec.generate_private_key(ec.SECP256R1())  # throwaway test key, never a real APNs key
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    token = provider_jwt("ABCDE12345", "KEY1234567", pem, now=1_760_000_000)
    header, claims, sig = token.split(".")
    pad = lambda s: s + "=" * (-len(s) % 4)
    assert json.loads(base64.urlsafe_b64decode(pad(header))) == {"alg": "ES256", "kid": "KEY1234567"}
    assert json.loads(base64.urlsafe_b64decode(pad(claims))) == {"iss": "ABCDE12345", "iat": 1_760_000_000}
    raw = base64.urlsafe_b64decode(pad(sig))
    key.public_key().verify(encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big")),
                            f"{header}.{claims}".encode(), ec.ECDSA(hashes.SHA256()))


def test_token_registry(tmp_path):
    reg = TokenRegistry(tmp_path / "t.json")
    with pytest.raises(ValueError):
        reg.register("dev1", "not-a-token", "production", None)
    reg.register("dev1", APNS_TOKEN, "development", {"job_done": False, "bogus": True})
    assert reg.for_device("dev1")[APNS_TOKEN]["prefs"] == {**DEFAULT_PREFS, "job_done": False}
    assert reg.targets("job_done") == [] and len(reg.targets("job_failed")) == 1
    reg.register("dev2", APNS_TOKEN, "production", None)  # moved to another device
    assert reg.for_device("dev1") == {}
    assert reg.prune({"dev1"}) == 1 and reg.targets("job_failed") == []
    assert oct(os.stat(tmp_path / "t.json").st_mode & 0o777) == "0o600"


class Recorder:
    def __init__(self, status=200):
        self.sent = []
        self.status = status

    async def __call__(self, token, environment, n: Notification):
        self.sent.append((token, environment, n))
        return self.status


def ready_push(tmp_path, fake_call, recorder):
    key = tmp_path / "AuthKey.p8"
    key.write_text("placeholder")  # never read: the sender is faked
    cfg = PushConfig(enabled=True, team_id="ABCDE12345", key_id="KEY1234567", key_file=str(key),
                     bundle_id="com.example.brainbox", long_task_seconds=10)
    return PushService(cfg, str(tmp_path / "state"), fake_call, send=recorder)


async def test_push_events_dedupe_and_generic_payloads(tmp_path):
    state = {"jobs": [{"id": "a1b2c3d4e5f6", "name": "Private payroll export",
                       "latest_execution": {"id": "e1", "status": "completed"}}],
             "health": 200, "runs": {}}

    async def call(method, path):
        if path.startswith("/api/jobs"):
            return 200, {"jobs": state["jobs"]}
        if path == "/health":
            return state["health"], {}
        rid = path.rsplit("/", 1)[-1]
        return (200, state["runs"][rid]) if rid in state["runs"] else (404, None)

    rec = Recorder()
    push = ready_push(tmp_path, call, rec)
    push.registry.register("dev1", APNS_TOKEN, "development", None)
    await push.tick()
    assert rec.sent == [], "the first look only remembers existing results"

    state["jobs"][0]["latest_execution"] = {"id": "e2", "status": "running"}
    await push.tick()
    state["jobs"][0]["latest_execution"] = {"id": "e2", "status": "failed"}
    await push.tick()
    await push.tick()
    kinds = [n.kind for _, _, n in rec.sent]
    assert kinds == ["job_failed"], kinds
    payload = json.dumps(rec.sent[0][2].payload())
    assert "payroll" not in payload and "a1b2c3d4e5f6" in payload and rec.sent[0][1] == "development"

    # A run started from the app: approval, then a long run finishing.
    push.watch_run("run_9", "dev1")
    push.runs["run_9"]["started"] -= 60
    state["runs"]["run_9"] = {"run_id": "run_9", "status": "waiting_for_approval", "updated_at": 5}
    await push.tick()
    await push.tick()
    state["runs"]["run_9"] = {"run_id": "run_9", "status": "completed"}
    await push.tick()
    assert [n.kind for _, _, n in rec.sent][1:] == ["approval", "long_task"]
    assert "run_9" not in push.runs

    # Hermes down three times → one connection alert, not one per poll.
    state["health"] = 503
    for _ in range(5):
        await push.tick()
    assert [n.kind for _, _, n in rec.sent].count("connection") == 1


async def test_push_preferences_and_dead_tokens(tmp_path):
    async def call(method, path):
        return 200, {"jobs": []}

    rec = Recorder(status=410)
    push = ready_push(tmp_path, call, rec)
    push.registry.register("dev1", APNS_TOKEN, "production", {"approval": False})
    assert await push.notify(Notification("approval", "t", "b", "brainbox://x", "k1")) == 0
    assert rec.sent == []
    await push.notify(Notification("job_done", "t", "b", "brainbox://x", "k2"))
    assert len(rec.sent) == 1 and push.registry.for_device("dev1") == {}, "Unregistered tokens are dropped"


async def test_push_endpoints(setup):
    client, *_ = setup
    r = await client.get("/hermes/brainbox/push", headers=auth())
    status = await r.json()
    assert status["enabled"] is False and status["ready"] is False and status["problems"]
    r = await client.post("/hermes/brainbox/push/register", json={"token": APNS_TOKEN, "environment": "development",
                                                                  "preferences": {"job_done": False}}, headers=auth())
    assert r.status == 200 and (await r.json())["prefs"]["job_done"] is False
    r = await client.post("/hermes/brainbox/push/register", json={"token": "zz"}, headers=auth())
    assert r.status == 400
    r = await client.post("/hermes/brainbox/push/test", headers=auth())
    assert r.status == 503, "never claims a test notification went out when push isn't configured"
    r = await client.delete("/hermes/brainbox/push/register", headers=auth())
    assert (await r.json())["removed"] == 1


async def test_runs_started_through_the_proxy_are_watched_only_when_enabled(setup):
    client, _fake, proxy, *_ = setup
    r = await client.post("/hermes/v1/runs", json={"input": "hi", "session_id": "ios_" + "e" * 32}, headers=auth())
    assert r.status == 202
    assert proxy.push.runs == {}, "push is off: nothing is watched"


# --------------------------------------------------------------------------- slash commands

STUB_COMMANDS = '''
from dataclasses import dataclass
@dataclass(frozen=True)
class CommandDef:
    name: str
    description: str
    category: str
    aliases: tuple = ()
    args_hint: str = ""
    cli_only: bool = False
    gateway_only: bool = False
COMMAND_REGISTRY = [CommandDef("compress", "Compress context", "Session", ("compact",)),
                    CommandDef("steer", "Steer the agent", "Session", (), "<text>")]
'''
STUB_SKILLS = '''
import os
def get_skill_commands():
    return {"/demo-skill": {"name": "demo-skill", "description": "Demo"}}
def resolve_skill_command_key(command):
    key = "/" + command.replace("_", "-")
    return key if key in get_skill_commands() else None
def build_skill_invocation_message(key, instruction=""):
    return f"[skill {key} home={os.environ['HERMES_HOME']} platform={os.environ['HERMES_PLATFORM']}] {instruction}"
'''


@pytest.fixture
def fake_hermes_install(tmp_path):
    src = tmp_path / "hermes-src"
    (src / "hermes_cli").mkdir(parents=True)
    (src / "agent").mkdir()
    (src / "hermes_cli" / "__init__.py").write_text("")
    (src / "agent" / "__init__.py").write_text("")
    (src / "hermes_cli" / "commands.py").write_text(STUB_COMMANDS)
    (src / "agent" / "skill_commands.py").write_text(STUB_SKILLS)
    bindir = src / "venv" / "bin"
    bindir.mkdir(parents=True)
    os.symlink(os.path.realpath(__import__("sys").executable), bindir / "python")
    (bindir / "hermes").write_text("#!/bin/sh\n")
    return str(bindir / "hermes")


async def test_command_catalog_and_skill_invocation(setup, fake_hermes_install):
    client, _fake, proxy, cfg, tmp_path = setup
    from brainbox_gateway.commands import CommandCatalog
    proxy.commands = CommandCatalog(fake_hermes_install, str(tmp_path / "hermes"))
    r = await client.get("/hermes/brainbox/commands", headers=auth())
    assert r.status == 200, await r.text()
    body = await r.json()
    assert body["api_runs_commands"] is False, "the API never runs commands itself"
    assert [c["name"] for c in body["native"]] == ["compress", "steer"]
    assert body["skills"] == [{"name": "demo-skill", "skill": "demo-skill", "description": "Demo"}]

    r = await client.post("/hermes/brainbox/commands/skill", json={"name": "demo_skill", "instruction": "check $(id) ; rm -rf /"},
                          headers=auth())
    assert r.status == 200, await r.text()
    message = (await r.json())["message"]
    assert message.startswith("[skill /demo-skill") and "platform=api_server" in message
    assert message.endswith("check $(id) ; rm -rf /"), "instruction passed as data, never through a shell"

    r = await client.post("/hermes/brainbox/commands/skill", json={"name": "nope"}, headers=auth())
    assert r.status == 404
    for bad in ("../x", "a b", "", "X" * 70):
        r = await client.post("/hermes/brainbox/commands/skill", json={"name": bad}, headers=auth())
        assert r.status == 400, bad
    r = await client.get("/hermes/brainbox/commands")
    assert r.status == 401


async def test_command_catalog_reports_missing_hermes(setup):
    client, _fake, proxy, *_ = setup
    from brainbox_gateway.commands import CommandCatalog
    proxy.commands = CommandCatalog("/nonexistent/venv/bin/hermes", "/tmp")
    r = await client.get("/hermes/brainbox/commands", headers=auth())
    assert r.status == 503 and (await r.json())["error"]["code"] == "hermes_python_missing"
