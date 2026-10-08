import asyncio
import os
import uuid

from brainbox_gateway.files import FileSandbox
from brainbox_gateway.config import FileRoot
from brainbox_gateway.system import MetricsSampler, journal_to_entry, server_info, processes
from brainbox_gateway.terminal import TerminalManager

SWIFT_METRICS_KEYS = {"cpuUsage", "memoryUsedBytes", "memoryTotalBytes", "diskUsedBytes", "diskTotalBytes",
                      "networkRxBytesPerSecond", "networkTxBytesPerSecond", "loadAverage", "timestamp"}


def sandbox(tmp_path):
    home = tmp_path / "home"
    ro = tmp_path / "ro"
    secret = tmp_path / "secret"
    for d in (home, ro, secret):
        d.mkdir()
    (home / "a.yaml").write_text("k: v\n")
    (ro / "log.txt").write_text("x")
    (secret / "key").write_text("private")
    os.symlink(secret, home / "escape")
    return FileSandbox([FileRoot(str(home)), FileRoot(str(ro), read_only=True)]), home, ro, secret


def code(fn):
    try:
        fn()
    except Exception as exc:
        return getattr(exc, "code", type(exc).__name__)
    return None


def test_sandbox_blocks_escape_and_enforces_read_only(tmp_path):
    fs, home, ro, secret = sandbox(tmp_path)
    assert code(lambda: fs.read(str(secret / "key"))) == "permission_denied"
    assert code(lambda: fs.read(str(home / ".." / "secret" / "key"))) == "permission_denied"
    assert code(lambda: fs.read(str(home / "escape" / "key"))) == "permission_denied", "symlink escape"
    assert "escape" not in [e["path"].split("/")[-1] for e in fs.list(str(home))]
    assert code(lambda: fs.write(str(ro / "log.txt"), "y", None)) == "permission_denied"
    assert code(lambda: fs.delete(str(home))) == "permission_denied", "roots are protected"
    assert code(lambda: fs.read("relative/path")) == "permission_denied"


def test_sandbox_crud_and_conflicts(tmp_path):
    fs, home, _, _ = sandbox(tmp_path)
    content = fs.read(str(home / "a.yaml"))
    saved = fs.write(content["path"], "k: w\n", content["version"])
    assert saved["version"] != content["version"]
    assert code(lambda: fs.write(content["path"], "stale", content["version"])) == "conflict"
    fs.create(str(home / "dir"), True)
    fs.create(str(home / "dir" / "n.md"), False)
    assert code(lambda: fs.create(str(home / "dir" / "n.md"), False)) == "permission_denied"
    renamed = fs.rename(str(home / "dir"), "dir2")
    assert renamed["path"].endswith("/dir2") and renamed["isDirectory"]
    assert [e["path"].split("/")[-1] for e in fs.search("n.md", str(home))] == ["n.md"]
    fs.delete(str(home / "dir2"))
    assert not (home / "dir2").exists()
    assert code(lambda: fs.rename(str(home / "a.yaml"), "../x")) == "permission_denied"
    entry = fs.list_roots()[0]
    assert set(entry) == {"path", "isDirectory", "size", "modifiedAt", "permissions", "isReadOnly"}


async def test_terminal_runs_tracks_cwd_and_interrupts(tmp_path):
    tm = TerminalManager(True, "/bin/bash", str(tmp_path))
    (tmp_path / "sub").mkdir()
    s = tm.get(tm.open()["id"])
    out = [c async for c in s.run("echo hi; echo err >&2; cd sub")]
    assert {"stream": "stdout", "data": "hi\n"} in out
    assert {"stream": "stderr", "data": "err\n"} in out
    assert out[-1] == {"stream": "exit", "code": 0}
    assert s.cwd == str(tmp_path / "sub")
    out = [c async for c in s.run("exit 3")]
    assert out[-1] == {"stream": "exit", "code": 3}

    async def long():
        return [c async for c in s.run("sleep 30")]
    task = asyncio.create_task(long())
    await asyncio.sleep(0.5)
    await s.interrupt()
    result = await asyncio.wait_for(task, 5)
    assert result[-1]["stream"] == "exit" and result[-1]["code"] != 0
    await tm.close_all()


def test_terminal_disabled_by_config():
    tm = TerminalManager(False, "/bin/bash", "/")
    try:
        tm.open()
        raise AssertionError
    except Exception as exc:
        assert exc.code == "permission_denied"


def test_metrics_info_and_processes_match_app_models():
    m = MetricsSampler().sample()
    assert set(m) == SWIFT_METRICS_KEYS and 0 <= m["cpuUsage"] <= 1
    info = server_info()
    assert {"hostname", "operatingSystem", "kernel", "architecture", "cpuCores", "bootedAt"} <= set(info)
    p = processes(5)
    assert p and set(p[0]) == {"pid", "name", "user", "cpu", "memoryBytes"}


def test_journal_mapping():
    e = journal_to_entry({"_SYSTEMD_UNIT": "hermes-gateway.service", "SYSLOG_IDENTIFIER": "python",
                          "PRIORITY": "3", "MESSAGE": "boom", "__REALTIME_TIMESTAMP": "1759900000000000"})
    assert e["category"] == "agent" and e["level"] == "error" and e["message"] == "boom"
    uuid.UUID(e["id"])
    assert e["timestamp"].endswith("Z")
    b = journal_to_entry({"_SYSTEMD_UNIT": "nginx.service", "MESSAGE": [104, 105]})
    assert b["category"] == "server" and b["message"] == "hi"


async def test_rpc_surface_end_to_end(gateway_factory, connect_client, tmp_path):
    _, url = await gateway_factory()
    c = await connect_client(url)
    await c.recv(); await c.recv()
    roots = await c.rpc("fs.roots")
    home = roots[0]["path"]
    listing = await c.rpc("fs.list", {"path": home})
    assert [e["path"].split("/")[-1] for e in listing] == ["notes.md"]
    content = await c.rpc("fs.read", {"path": home + "/notes.md"})
    saved = await c.rpc("fs.write", {"path": home + "/notes.md", "text": "# edited\n", "expectedVersion": content["version"]})
    assert saved["text"] == "# edited\n"
    stale = await c.rpc("fs.write", {"path": home + "/notes.md", "text": "x", "expectedVersion": content["version"]})
    assert stale["error"]["code"] == "conflict"
    assert (await c.rpc("fs.read", {"path": "/etc/passwd"}))["error"]["code"] == "permission_denied"
    assert set(await c.rpc("vps.metrics")) == SWIFT_METRICS_KEYS
    assert (await c.rpc("vps.services")) == []
    assert (await c.rpc("vps.service.action", {"name": "ssh", "action": "stop"}))["error"]["code"] == "permission_denied"

    session = await c.rpc("terminal.open")
    rid = str(uuid.uuid4())
    await c.send("stream.subscribe", {"method": "terminal.run", "params": {"sessionId": session["id"], "command": "echo bb"}}, rid)
    frames = await c.until_terminal(rid)
    data = [f["payload"] for f in frames if f["type"] == "stream.data"]
    assert {"stream": "stdout", "data": "bb\n"} in data and data[-1] == {"stream": "exit", "code": 0}
    assert frames[-1]["type"] == "stream.end"

    rid = str(uuid.uuid4())
    await c.send("stream.subscribe", {"method": "vps.metrics", "params": {"intervalSeconds": 0.5}}, rid)
    first = await c.recv()
    assert first["type"] == "stream.data" and first["requestId"] == rid
    await c.send("stream.unsubscribe", {}, rid)
