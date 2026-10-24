"""Chat session listing, ownership and verified permanent deletion.

The fake Hermes below mirrors hermes-agent 284d220 `SessionDB.delete_session` as called by the
HTTP API: deletes the row and its messages, orphans other children, and leaves files alone."""
import json
import os
import sqlite3

import pytest
from aiohttp import web
from aiohttp.test_utils import TestServer

from brainbox_gateway import config as cfgmod
from brainbox_gateway import hermes_proxy as hp
from brainbox_gateway.chat_sessions import (OwnershipRegistry, ReadOnlySessionStore, is_app_session,
                                            remove_session_files)

TOKEN_A = "device-a-token-abcdefghijklmnopqrstuvwxyz"
TOKEN_B = "device-b-token-abcdefghijklmnopqrstuvwxyz"
HERMES_KEY = "server-side-hermes-key-0123456789abcdef"

ROOT = "ios_" + "a" * 32
OTHER_APP = "ios_" + "b" * 32
ARCHIVED = "ios_" + "c" * 32
CHILD_1 = "20261022_100000_c1"      # compression continuation of ROOT
CHILD_2 = "20261022_110000_c2"      # continuation of CHILD_1
BRANCH = "api_1761130000_fork1"     # a fork of ROOT: separate conversation, must survive
TELEGRAM = "agent:main:telegram:dm:42"
CRON = "cron_a1b2c3d4e5f6_20261022_090000"

SCHEMA = """
CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, title TEXT, parent_session_id TEXT,
  started_at REAL NOT NULL, ended_at REAL, end_reason TEXT, message_count INTEGER DEFAULT 0,
  archived INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0, model_config TEXT);
CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, role TEXT, content TEXT, timestamp REAL);
"""


def seed(db_path):
    conn = sqlite3.connect(db_path)
    conn.executescript(SCHEMA)
    rows = [
        (ROOT, "api_server", "Long chat", None, 100.0, 200.0, "compression", 0),
        (CHILD_1, "api_server", "Long chat", ROOT, 200.0, 300.0, "compression", 0),
        (CHILD_2, "api_server", "Long chat", CHILD_1, 300.0, None, None, 0),
        (BRANCH, "api_server", "Long chat fork", ROOT, 250.0, None, None, 0),
        (OTHER_APP, "api_server", "Other device chat", None, 150.0, None, None, 0),
        (ARCHIVED, "api_server", "Old chat", None, 50.0, None, None, 1),
        (TELEGRAM, "telegram", "Telegram DM", None, 10.0, None, None, 0),
        (CRON, "cron", "Morning summary · Oct 22 09:00", None, 90.0, 95.0, None, 0),
    ]
    conn.executemany("INSERT INTO sessions (id, source, title, parent_session_id, started_at, ended_at, end_reason, archived) "
                     "VALUES (?,?,?,?,?,?,?,?)", rows)
    for sid, _, *_ in rows:
        conn.executemany("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?,?,?,?)",
                         [(sid, "user", f"hello from {sid}", 1.0), (sid, "assistant", f"reply in {sid}", 2.0)])
    # Hermes marks /branch children in model_config (the stable marker _BRANCH_CHILD_SQL checks).
    conn.execute("UPDATE sessions SET model_config = ? WHERE id = ?", (json.dumps({"_branched_from": ROOT}), BRANCH))
    conn.commit()
    conn.close()


class FakeHermes:
    def __init__(self, db_path):
        self.db_path = db_path
        self.seen = []
        self.fail_delete = set()

    def app(self):
        app = web.Application()

        async def get_session(request):
            sid = request.match_info["sid"]
            self.seen.append(("GET", request.path))
            conn = sqlite3.connect(self.db_path)
            row = conn.execute("SELECT id FROM sessions WHERE id = ?", (sid,)).fetchone()
            conn.close()
            if not row:
                return web.json_response({"error": "not found"}, status=404)
            return web.json_response({"object": "hermes.session", "session": {"id": sid}})

        async def delete_session(request):
            sid = request.match_info["sid"]
            self.seen.append(("DELETE", request.path))
            assert request.headers["Authorization"] == f"Bearer {HERMES_KEY}"
            if sid in self.fail_delete:
                return web.json_response({"error": "boom"}, status=500)
            conn = sqlite3.connect(self.db_path)
            if not conn.execute("SELECT 1 FROM sessions WHERE id = ?", (sid,)).fetchone():
                conn.close()
                return web.json_response({"error": "not found"}, status=404)
            conn.execute("UPDATE sessions SET parent_session_id = NULL WHERE parent_session_id = ?", (sid,))
            conn.execute("DELETE FROM messages WHERE session_id = ?", (sid,))
            conn.execute("DELETE FROM sessions WHERE id = ?", (sid,))
            conn.commit()
            conn.close()
            return web.json_response({"object": "hermes.session.deleted", "id": sid, "deleted": True})

        async def other(request):
            self.seen.append((request.method, request.path))
            if request.method == "POST" and request.path == "/api/sessions":
                return web.json_response({"session": {"id": (await request.json())["id"]}}, status=201)
            return web.json_response({"ok": True})

        app.router.add_get("/api/sessions/{sid}", get_session)
        app.router.add_delete("/api/sessions/{sid}", delete_session)
        app.router.add_route("*", "/{tail:.*}", other)
        return app


@pytest.fixture
def hermes_home(tmp_path):
    home = tmp_path / "hermes"
    (home / "sessions").mkdir(parents=True)
    seed(str(home / "state.db"))
    for sid in (ROOT, CHILD_1, CHILD_2, BRANCH, TELEGRAM, CRON):
        (home / "sessions" / f"request_dump_{sid}_20261022_100000_000001.json").write_text("{}")
    (home / "sessions" / f"{ROOT}.jsonl").write_text("{}\n")
    (home / "sessions" / f"{TELEGRAM}.jsonl").write_text("{}\n")
    return home


@pytest.fixture
async def setup(aiohttp_client, tmp_path, hermes_home):
    fake = FakeHermes(str(hermes_home / "state.db"))
    server = TestServer(fake.app())
    await server.start_server()
    env = tmp_path / "hermes.env"
    env.write_text(f"API_SERVER_KEY={HERMES_KEY}\n")
    cfg = hp.config_from_dict({
        "proxy": {"hermes_url": str(server.make_url("")).rstrip("/"), "hermes_env_file": str(env),
                  "audit_log": str(tmp_path / "audit.log"), "state_dir": str(tmp_path / "state"),
                  "max_requests_per_minute": 1000},
        "devices": [{"name": "Phone A", "token_sha256": cfgmod.hash_token(TOKEN_A)},
                    {"name": "Phone B", "token_sha256": cfgmod.hash_token(TOKEN_B)}],
        "profiles": {"hermes_home": str(hermes_home)},
    })
    proxy = hp.HermesProxy(cfg)
    client = await aiohttp_client(proxy.app())
    key_a = cfgmod.hash_token(TOKEN_A)[:24]
    key_b = cfgmod.hash_token(TOKEN_B)[:24]
    proxy.owners.record(ROOT, key_a)
    proxy.owners.record(OTHER_APP, key_b)
    yield client, fake, proxy, cfg, hermes_home
    await server.close()


def auth(token=TOKEN_A):
    return {"Authorization": f"Bearer {token}"}


def ids_in_db(home):
    conn = sqlite3.connect(str(home / "state.db"))
    ids = {r[0] for r in conn.execute("SELECT id FROM sessions")}
    msgs = {r[0] for r in conn.execute("SELECT DISTINCT session_id FROM messages")}
    conn.close()
    return ids, msgs


# --------------------------------------------------------------------------- listing

async def test_lists_only_this_devices_app_sessions_including_archived(setup):
    client, fake, *_ = setup
    r = await client.get("/hermes/brainbox/sessions", headers=auth())
    assert r.status == 200
    active = [s["id"] for s in (await r.json())["data"]]
    assert active == [ROOT]  # OTHER_APP belongs to Phone B; Telegram, cron, children excluded
    r = await client.get("/hermes/brainbox/sessions?state=archived", headers=auth())
    archived = (await r.json())["data"]
    assert [s["id"] for s in archived] == [ARCHIVED]  # unowned legacy session is visible
    assert archived[0]["archived"] is True and archived[0]["owned"] is False
    r = await client.get("/hermes/brainbox/sessions", headers=auth(TOKEN_B))
    assert [s["id"] for s in (await r.json())["data"]] == [OTHER_APP]
    assert fake.seen == []  # listing never calls Hermes
    assert (await client.get("/hermes/brainbox/sessions?state=all", headers=auth())).status == 400
    assert (await client.get("/hermes/brainbox/sessions")).status == 401


# --------------------------------------------------------------------------- delete

async def test_permanent_delete_removes_whole_conversation_and_files_only(setup):
    client, fake, proxy, cfg, home = setup
    r = await client.delete(f"/hermes/brainbox/sessions/{ROOT}", headers=auth())
    assert r.status == 200, await r.text()
    body = await r.json()
    assert body["verified"] is True
    assert body["deleted_sessions"] == [CHILD_2, CHILD_1, ROOT]  # continuations deepest first, root last
    assert body["files_removed"] == 4  # 3 request dumps + ROOT.jsonl
    ids, msgs = ids_in_db(home)
    for gone in (ROOT, CHILD_1, CHILD_2):
        assert gone not in ids and gone not in msgs
    for kept in (BRANCH, OTHER_APP, ARCHIVED, TELEGRAM, CRON):
        assert kept in ids and kept in msgs
    files = set(os.listdir(home / "sessions"))
    assert f"{TELEGRAM}.jsonl" in files
    assert {f"request_dump_{s}_20261022_100000_000001.json" for s in (BRANCH, TELEGRAM, CRON)} <= files
    assert not any(ROOT in f or CHILD_1 in f or CHILD_2 in f for f in files)
    assert proxy.owners.owner(ROOT) is None
    # Hermes only ever saw deletes for the conversation's own sessions.
    assert [p for m, p in fake.seen if m == "DELETE"] == [f"/api/sessions/{s}" for s in (CHILD_2, CHILD_1, ROOT)]
    # Gone after a fresh server-backed fetch.
    listed = await (await client.get("/hermes/brainbox/sessions", headers=auth())).json()
    assert ROOT not in [s["id"] for s in listed["data"]]
    audit = open(cfg.audit_log).read()
    assert "hello from" not in audit and "reply in" not in audit
    # Deleting again is an honest 404.
    r = await client.delete(f"/hermes/brainbox/sessions/{ROOT}", headers=auth())
    assert r.status == 404
    assert (await r.json())["error"]["code"] == "session_not_found"


@pytest.mark.parametrize("target", [TELEGRAM, CRON, BRANCH, CHILD_1, "ios_" + "A" * 32, "ios_123", "..%2Fstate.db",
                                    "ios_" + "a" * 31 + "%2F", "ios_" + "a" * 33])
async def test_only_app_session_ids_can_be_deleted(setup, target):
    client, fake, proxy, cfg, home = setup
    before = ids_in_db(home)
    r = await client.delete(f"/hermes/brainbox/sessions/{target}", headers=auth())
    assert r.status in (400, 404)
    assert [m for m, _ in fake.seen if m == "DELETE"] == []
    assert ids_in_db(home) == before


async def test_another_devices_conversation_cannot_be_deleted_or_changed(setup):
    client, fake, proxy, cfg, home = setup
    before = ids_in_db(home)
    r = await client.delete(f"/hermes/brainbox/sessions/{OTHER_APP}", headers=auth(TOKEN_A))
    assert r.status == 403 and (await r.json())["error"]["code"] == "session_not_owned"
    r = await client.patch(f"/hermes/api/sessions/{OTHER_APP}", json={"archived": True}, headers=auth(TOKEN_A))
    assert r.status == 403
    r = await client.post("/hermes/v1/runs", json={"input": "x", "session_id": OTHER_APP}, headers=auth(TOKEN_A))
    assert r.status == 403
    assert fake.seen == []
    assert ids_in_db(home) == before


async def test_backend_failure_is_reported_and_nothing_claimed(setup):
    client, fake, proxy, cfg, home = setup
    fake.fail_delete.add(ROOT)
    r = await client.delete(f"/hermes/brainbox/sessions/{ROOT}", headers=auth())
    assert r.status == 502
    body = await r.json()
    assert body["error"]["code"] == "delete_failed"
    assert body["remaining_sessions"] == [ROOT]
    ids, _ = ids_in_db(home)
    assert ROOT in ids
    assert proxy.owners.owner(ROOT) is not None  # still owned, can retry


async def test_unreadable_session_database_deletes_nothing(setup):
    client, fake, proxy, cfg, home = setup
    os.rename(home / "state.db", home / "state.db.moved")
    r = await client.delete(f"/hermes/brainbox/sessions/{ROOT}", headers=auth())
    assert r.status == 503
    assert fake.seen == []
    r = await client.get("/hermes/brainbox/sessions", headers=auth())
    assert r.status == 503


async def test_legacy_unowned_session_is_claimed_by_first_manager(setup):
    client, fake, proxy, cfg, home = setup
    assert proxy.owners.owner(ARCHIVED) is None
    r = await client.patch(f"/hermes/api/sessions/{ARCHIVED}", json={"archived": False}, headers=auth(TOKEN_B))
    assert r.status == 200
    assert proxy.owners.owner(ARCHIVED) == cfgmod.hash_token(TOKEN_B)[:24]
    r = await client.delete(f"/hermes/brainbox/sessions/{ARCHIVED}", headers=auth(TOKEN_A))
    assert r.status == 403


async def test_creating_a_session_records_its_owner(setup):
    client, fake, proxy, *_ = setup
    new_id = "ios_" + "d" * 32
    r = await client.post("/hermes/api/sessions", json={"id": new_id, "source": "api_server"}, headers=auth(TOKEN_B))
    assert r.status == 201
    assert proxy.owners.owner(new_id) == cfgmod.hash_token(TOKEN_B)[:24]
    r = await client.patch(f"/hermes/api/sessions/{new_id}", json={"archived": True}, headers=auth(TOKEN_A))
    assert r.status == 403


# --------------------------------------------------------------------------- units

def test_store_is_read_only(hermes_home):
    store = ReadOnlySessionStore(str(hermes_home / "state.db"))
    conn = store._connect()
    with pytest.raises(sqlite3.OperationalError):
        conn.execute("DELETE FROM sessions")
    conn.close()
    assert store.continuation_chain(ROOT) == [CHILD_2, CHILD_1]
    assert store.continuation_chain(TELEGRAM) == []


def test_file_cleanup_never_leaves_the_sessions_dir(tmp_path):
    sessions = tmp_path / "sessions"
    sessions.mkdir()
    outside = tmp_path / "secret.json"
    outside.write_text("keep")
    (sessions / f"{ROOT}.json").symlink_to(outside)
    (sessions / f"request_dump_{ROOT}_1.json").write_text("{}")
    removed = remove_session_files(str(sessions), ROOT)
    assert removed == [f"request_dump_{ROOT}_1.json"]
    assert outside.read_text() == "keep"
    assert remove_session_files(str(sessions), "../secret") == []
    assert remove_session_files(str(sessions), "..") == []


def test_ownership_registry_file_is_private(tmp_path):
    reg = OwnershipRegistry(str(tmp_path / "state" / "owners.json"))
    reg.record(ROOT, "k1")
    reg.record(ROOT, "k2")  # first owner wins
    assert reg.owner(ROOT) == "k1"
    assert oct(os.stat(reg.path).st_mode & 0o777) == "0o600"
    assert reg.may_manage(ROOT, "k1") and not reg.may_manage(ROOT, "k2") and reg.may_manage(ROOT, "k2", admin=True)
    reg.forget(ROOT)
    assert reg.owner(ROOT) is None
    assert is_app_session(ROOT) and not is_app_session(TELEGRAM) and not is_app_session(CRON)
