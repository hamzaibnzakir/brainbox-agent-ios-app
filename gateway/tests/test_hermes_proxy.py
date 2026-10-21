"""Hermes proxy: auth, allow-list, key isolation, SSE passthrough, profiles, audit."""
import json
import os
import stat
import sys
import textwrap

import pytest
from aiohttp import web
from aiohttp.test_utils import TestServer

from brainbox_gateway import config as cfgmod
from brainbox_gateway import hermes_proxy as hp

DEVICE_TOKEN = "device-token-abcdefghijklmnopqrstuvwxyz"
ADMIN_TOKEN = "admin-token-abcdefghijklmnopqrstuvwxyz0"
HERMES_KEY = "server-side-hermes-key-0123456789abcdef"


class FakeHermes:
    """Records what reached 'Hermes' so tests can assert key isolation."""

    def __init__(self):
        self.seen = []

    def app(self):
        app = web.Application()

        async def record(request):
            self.seen.append({"method": request.method, "path": request.path, "query": dict(request.query),
                              "auth": request.headers.get("Authorization"),
                              "idem": request.headers.get("Idempotency-Key"),
                              "cookie": request.headers.get("Cookie"),
                              "session_key": request.headers.get("X-Hermes-Session-Key"),
                              "session_hdr": request.headers.get("X-Hermes-Session-Id"),
                              "body": (await request.text()) if request.can_read_body else ""})

        async def capabilities(request):
            await record(request)
            return web.json_response({"object": "hermes.api_server.capabilities"})

        async def health(request):
            await record(request)
            return web.json_response({"status": "ok"})

        async def runs(request):
            await record(request)
            return web.json_response({"run_id": "run_1", "status": "started"}, status=202,
                                     headers={"Idempotency-Replayed": "false", "Set-Cookie": "x=y"})

        async def events(request):
            await record(request)
            resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"})
            await resp.prepare(request)
            await resp.write(b'data: {"event":"message.delta","delta":"hi"}\n\n')
            await resp.write(b": keepalive\n\n")
            await resp.write(b'data: {"event":"run.completed","output":"hi"}\n\n')
            return resp

        async def catch_all(request):
            await record(request)
            return web.json_response({"ok": True, "path": request.path})

        app.router.add_get("/health", health)
        app.router.add_get("/v1/capabilities", capabilities)
        app.router.add_get("/p/research/v1/capabilities", capabilities)
        app.router.add_post("/v1/runs", runs)
        app.router.add_get("/v1/runs/{run_id}/events", events)
        app.router.add_route("*", "/{tail:.*}", catch_all)
        return app


def make_cfg(tmp_path, upstream_url, **overrides):
    home = tmp_path / "hermes-home"
    (home / "profiles" / "research").mkdir(parents=True, exist_ok=True)
    (home / "profiles" / "research" / ".env").write_text('API_SERVER_KEY="research-key-0123456789abcdef"\n')
    (home / "profiles" / "nokey").mkdir(exist_ok=True)
    (home / "profiles" / "Bad Name").mkdir(exist_ok=True)
    env = tmp_path / "hermes.env"
    env.write_text(f"# hermes env\nTELEGRAM_BOT_TOKEN=never-forwarded\nexport API_SERVER_KEY={HERMES_KEY}\n")
    raw = {
        "proxy": {"host": "127.0.0.1", "port": 0, "path_prefix": "/hermes", "hermes_url": upstream_url,
                  "hermes_env_file": str(env), "audit_log": str(tmp_path / "audit.log"),
                  "max_auth_failures_per_minute": 3, "max_requests_per_minute": 1000},
        "devices": [{"name": "David's iPhone", "token_sha256": cfgmod.hash_token(DEVICE_TOKEN)},
                    {"name": "Admin iPhone", "token_sha256": cfgmod.hash_token(ADMIN_TOKEN), "admin": True}],
        "profiles": {"hermes_home": str(home), "hermes_bin": str(tmp_path / "fake-hermes"), "multiplex": False,
                     "admin_enabled": False},
    }
    for key, value in overrides.items():
        section, field = key.split("__")
        raw.setdefault(section, {})[field] = value
    return hp.config_from_dict(raw)


@pytest.fixture
async def upstream():
    fake = FakeHermes()
    server = TestServer(fake.app())
    await server.start_server()
    yield fake, str(server.make_url("")).rstrip("/")
    await server.close()


@pytest.fixture
def make_client(aiohttp_client, upstream, tmp_path):
    fake, url = upstream

    async def factory(**overrides):
        cfg = make_cfg(tmp_path, url, **overrides)
        client = await aiohttp_client(hp.HermesProxy(cfg).app())
        return client, fake, cfg

    return factory


def auth(token=DEVICE_TOKEN):
    return {"Authorization": f"Bearer {token}"}


async def test_requires_device_token_and_never_forwards_it(make_client):
    client, fake, _ = await make_client()
    r = await client.get("/hermes/v1/capabilities")
    assert r.status == 401
    r = await client.get("/hermes/v1/capabilities", headers=auth("wrong-token-wrong-token-wrong"))
    assert r.status == 401
    assert fake.seen == []
    r = await client.get("/hermes/v1/capabilities", headers={**auth(), "Cookie": "session=1"})
    assert r.status == 200
    assert fake.seen[-1]["auth"] == f"Bearer {HERMES_KEY}"
    assert DEVICE_TOKEN not in json.dumps(fake.seen)
    assert fake.seen[-1]["cookie"] is None


async def test_health_is_public(make_client):
    client, fake, _ = await make_client()
    r = await client.get("/hermes/health")
    assert r.status == 200
    assert (await r.json())["status"] == "ok"


async def test_auth_failures_are_rate_limited(make_client):
    client, _, _ = await make_client()
    for _ in range(3):
        assert (await client.get("/hermes/v1/capabilities", headers=auth("bad-token-bad-token-bad-token-x"))).status == 401
    r = await client.get("/hermes/v1/capabilities", headers=auth())
    assert r.status == 429  # even a good token waits once the address is blocked


@pytest.mark.parametrize("method,path", [
    ("POST", "/v1/chat/completions"), ("POST", "/v1/responses"), ("POST", "/v1/browser-control/register"),
    ("POST", "/v1/artifacts/upload"), ("POST", "/api/platforms/telegram/events"), ("POST", "/api/cron/fire"),
    ("POST", "/api/sessions/abc/model"), ("GET", "/../../etc/passwd"), ("DELETE", "/v1/runs/x"),
    ("GET", "/api/jobs/../../x"), ("POST", "/api/jobs/NOTAJOBID/run"),
])
async def test_routes_outside_allow_list_are_refused(make_client, method, path):
    client, fake, _ = await make_client()
    r = await client.request(method, "/hermes" + path, headers=auth())
    assert r.status in (404, 400)
    assert fake.seen == []


async def test_run_creation_forwards_safe_headers_only(make_client):
    client, fake, cfg = await make_client()
    r = await client.post("/hermes/v1/runs", json={"input": "hi", "session_id": "ios_x"},
                          headers={**auth(), "Idempotency-Key": "abc", "X-Evil": "1"})
    assert r.status == 202
    assert r.headers.get("Idempotency-Replayed") == "false"
    assert "Set-Cookie" not in r.headers
    assert fake.seen[-1]["idem"] == "abc"
    assert json.loads(fake.seen[-1]["body"]) == {"input": "hi", "session_id": "ios_x"}
    audit = [json.loads(line) for line in open(cfg.audit_log)]
    assert audit[-1]["method"] == "POST" and audit[-1]["path"] == "/v1/runs" and audit[-1]["status"] == 202
    assert audit[-1]["device"] == "David's iPhone"
    assert "hi" not in open(cfg.audit_log).read()  # bodies are never logged
    assert stat.S_IMODE(os.stat(cfg.audit_log).st_mode) == 0o600


async def test_sse_events_are_streamed_through(make_client):
    client, _, _ = await make_client()
    r = await client.get("/hermes/v1/runs/run_1/events", headers=auth())
    assert r.status == 200
    assert r.headers["Content-Type"].startswith("text/event-stream")
    text = await r.text()
    assert '"message.delta"' in text and '"run.completed"' in text and ": keepalive" in text


async def test_query_strings_are_forwarded(make_client):
    client, fake, _ = await make_client()
    r = await client.get("/hermes/api/sessions?limit=20&offset=40&source=telegram", headers=auth())
    assert r.status == 200
    assert fake.seen[-1]["query"] == {"limit": "20", "offset": "40", "source": "telegram"}


async def test_telegram_session_ids_with_colons_are_allowed(make_client):
    client, fake, _ = await make_client()
    r = await client.get("/hermes/api/sessions/agent:main:telegram:dm:42/messages", headers=auth())
    assert r.status == 200
    assert fake.seen[-1]["path"] == "/api/sessions/agent:main:telegram:dm:42/messages"


async def test_profile_routing_is_off_by_default_and_uses_profile_key(make_client):
    client, fake, _ = await make_client()
    r = await client.get("/hermes/p/research/v1/capabilities", headers=auth())
    assert r.status == 404
    client, fake, _ = await make_client(profiles__multiplex=True)
    r = await client.get("/hermes/p/research/v1/capabilities", headers=auth())
    assert r.status == 200
    assert fake.seen[-1]["path"] == "/p/research/v1/capabilities"
    assert fake.seen[-1]["auth"] == "Bearer research-key-0123456789abcdef"
    r = await client.get("/hermes/p/nokey/v1/capabilities", headers=auth())
    assert r.status == 503
    r = await client.get("/hermes/p/..%2Fetc/v1/capabilities", headers=auth())
    assert r.status in (400, 404)


async def test_profile_listing(make_client):
    client, _, _ = await make_client(profiles__multiplex=True)
    r = await client.get("/hermes/brainbox/profiles", headers=auth())
    profiles = {p["name"]: p for p in (await r.json())["profiles"]}
    assert set(profiles) == {"default", "research", "nokey"}  # invalid dir names are hidden
    assert profiles["research"]["routable"] is True
    assert profiles["nokey"]["has_api_key"] is False


def write_fake_hermes(tmp_path, exit_code=0):
    script = tmp_path / "fake-hermes"
    script.write_text(textwrap.dedent(f"""\
        #!{sys.executable}
        import os, sys, json
        args = sys.argv[1:]
        with open(os.path.join(os.environ["HERMES_HOME"], "..", "calls.json"), "a") as fh:
            fh.write(json.dumps(args) + "\\n")
        if {exit_code} == 0 and args[:2] == ["profile", "create"]:
            os.makedirs(os.path.join(os.environ["HERMES_HOME"], "profiles", args[2]))
        sys.exit({exit_code})
    """))
    script.chmod(0o755)
    return tmp_path / "calls.json"


async def test_profile_creation_requires_admin_device_and_flag(make_client, tmp_path):
    calls = write_fake_hermes(tmp_path)
    client, _, cfg = await make_client()
    r = await client.post("/hermes/brainbox/profiles", json={"name": "ops"}, headers=auth(ADMIN_TOKEN))
    assert r.status == 403  # flag off
    client, _, cfg = await make_client(profiles__admin_enabled=True)
    r = await client.post("/hermes/brainbox/profiles", json={"name": "ops"}, headers=auth())
    assert r.status == 403  # non-admin device
    assert not calls.exists()


@pytest.mark.parametrize("name", ["", "Ops", "1ops", "ops;rm -rf /", "../x", "default", "a" * 33, "--help"])
async def test_profile_names_are_validated(make_client, tmp_path, name):
    calls = write_fake_hermes(tmp_path)
    client, _, _ = await make_client(profiles__admin_enabled=True)
    r = await client.post("/hermes/brainbox/profiles", json={"name": name}, headers=auth(ADMIN_TOKEN))
    assert r.status == 400
    assert not calls.exists()


async def test_profile_creation_runs_argv_and_audits(make_client, tmp_path):
    calls = write_fake_hermes(tmp_path)
    client, _, cfg = await make_client(profiles__admin_enabled=True)
    r = await client.post("/hermes/brainbox/profiles", json={"name": "ops", "description": "Runs the servers; carefully", "clone": True},
                          headers=auth(ADMIN_TOKEN))
    assert r.status == 201, await r.text()
    assert (await r.json())["profile"]["name"] == "ops"
    args = json.loads(calls.read_text().splitlines()[0])
    assert args == ["profile", "create", "ops", "--clone", "--description", "Runs the servers; carefully"]
    r = await client.post("/hermes/brainbox/profiles", json={"name": "ops"}, headers=auth(ADMIN_TOKEN))
    assert r.status == 409
    audit = [json.loads(line) for line in open(cfg.audit_log)]
    assert any(e.get("action") == "profile.create" and e.get("outcome") == "ok" and e.get("profile") == "ops" for e in audit)
    r = await client.post("/hermes/brainbox/profiles", json={"name": "bad", "description": "line1\nline2"}, headers=auth(ADMIN_TOKEN))
    assert r.status == 400


async def test_failed_profile_creation_does_not_leak_output(make_client, tmp_path):
    write_fake_hermes(tmp_path, exit_code=3)
    client, _, _ = await make_client(profiles__admin_enabled=True)
    r = await client.post("/hermes/brainbox/profiles", json={"name": "ops"}, headers=auth(ADMIN_TOKEN))
    assert r.status == 500
    assert "Check the server log" in (await r.json())["error"]["message"]


async def test_info_reports_device_and_admin(make_client):
    client, _, _ = await make_client(profiles__admin_enabled=True)
    info = await (await client.get("/hermes/brainbox/info", headers=auth(ADMIN_TOKEN))).json()
    assert info["service"] == "brainbox-hermes-proxy" and info["profile_admin"] is True
    info = await (await client.get("/hermes/brainbox/info", headers=auth())).json()
    assert info["profile_admin"] is False and info["device_name"] == "David's iPhone"


async def test_unreachable_hermes_is_a_clean_502(aiohttp_client, tmp_path):
    cfg = make_cfg(tmp_path, "http://127.0.0.1:9")
    client = await aiohttp_client(hp.HermesProxy(cfg).app())
    r = await client.get("/hermes/v1/capabilities", headers=auth())
    assert r.status == 502
    assert (await r.json())["error"]["code"] == "hermes_unreachable"


def test_config_validation(tmp_path):
    with pytest.raises(ValueError):
        hp.config_from_dict({"proxy": {"hermes_env_file": "/x"}, "devices": []})
    with pytest.raises(ValueError):
        hp.config_from_dict({"proxy": {"hermes_env_file": "/x"}, "devices": [{"name": "a", "token_sha256": "short"}]})
    with pytest.raises(ValueError):
        hp.config_from_dict({"proxy": {}, "devices": [{"name": "a", "token_sha256": "a" * 64}]})


def test_env_parsing_handles_quotes_comments_and_export(tmp_path):
    env = tmp_path / ".env"
    env.write_text("# c\nAPI_SERVER_KEY='first'\nOTHER=x\nexport API_SERVER_KEY = \"second\"\n")
    assert hp.read_env_value(str(env), "API_SERVER_KEY") == "second"
    assert hp.read_env_value(str(tmp_path / "missing"), "API_SERVER_KEY") == ""


def test_split_profile():
    assert hp.split_profile("/p/research/v1/runs") == ("research", "/v1/runs")
    assert hp.split_profile("/v1/runs") == (None, "/v1/runs")


def test_upstream_must_be_loopback():
    dev = [{"name": "a", "token_sha256": "a" * 64}]
    for bad in ("http://10.0.0.5:8642", "https://hermes.example.com", "ftp://127.0.0.1"):
        with pytest.raises(ValueError):
            hp.config_from_dict({"proxy": {"hermes_env_file": "/x", "hermes_url": bad}, "devices": dev})
    cfg = hp.config_from_dict({"proxy": {"hermes_env_file": "/x", "hermes_url": "http://localhost:8642"}, "devices": dev})
    assert cfg.hermes_url == "http://localhost:8642"


def test_insecure_permissions(tmp_path):
    f = tmp_path / "k"
    f.write_text("x")
    f.chmod(0o600)
    assert not hp.insecure_permissions(str(f))
    f.chmod(0o644)
    assert hp.insecure_permissions(str(f))
    assert not hp.insecure_permissions(str(tmp_path / "missing"))


# --------------------------------------------------------------------------- session guard
TELEGRAM_ID = "agent:main:telegram:dm:42"


@pytest.mark.parametrize("method,path,body", [
    ("POST", f"/api/sessions/{TELEGRAM_ID}/fork", {"title": "copy"}),
    ("POST", "/api/sessions/api_1700000000_abcd1234/fork", {}),
    ("POST", f"/api/sessions/{TELEGRAM_ID}/chat", {"message": "hi"}),
    ("POST", f"/api/sessions/{TELEGRAM_ID}/chat/stream", {"message": "hi"}),
    ("PATCH", f"/api/sessions/{TELEGRAM_ID}", {"title": "renamed"}),
    ("DELETE", f"/api/sessions/{TELEGRAM_ID}", None),
    ("POST", "/v1/runs", {"input": "hi", "session_id": TELEGRAM_ID}),
    ("POST", "/v1/runs", {"input": "hi", "session_id": "ios_"}),
    ("POST", "/v1/runs", {"input": "hi", "previous_response_id": "resp_1"}),
    ("POST", "/api/sessions", {"id": "my-session"}),
    ("POST", "/api/sessions", {}),
    ("POST", "/api/sessions", {"id": "ios_abc", "source": "telegram"}),
])
async def test_writes_to_non_app_sessions_never_reach_hermes(make_client, method, path, body):
    client, fake, cfg = await make_client()
    kwargs = {"headers": auth()}
    if body is not None:
        kwargs["json"] = body
    r = await client.request(method, "/hermes" + path, **kwargs)
    assert r.status == 403
    assert fake.seen == []  # refused before anything was forwarded
    audit = [json.loads(line) for line in open(cfg.audit_log)]
    assert audit[-1]["action"] == "guard" and audit[-1]["device"] == "David's iPhone"


@pytest.mark.parametrize("method,path,body", [
    ("POST", "/api/sessions", {"id": "ios_0123456789abcdef", "source": "api_server", "title": "t"}),
    ("POST", "/api/sessions", {"id": "ios_0123456789abcdef"}),
    ("POST", "/api/sessions/ios_0123456789abcdef/fork", {"title": "t"}),
    ("PATCH", "/api/sessions/ios_0123456789abcdef", {"title": "t"}),
    ("DELETE", "/api/sessions/ios_0123456789abcdef", None),
    ("POST", "/v1/runs", {"input": "hi", "session_id": "ios_0123456789abcdef",
                          "conversation_history": [{"role": "user", "content": "earlier"}]}),
    ("POST", "/v1/runs", {"input": "hi"}),
])
async def test_writes_to_app_sessions_are_forwarded(make_client, method, path, body):
    client, fake, _ = await make_client()
    kwargs = {"headers": auth()}
    if body is not None:
        kwargs["json"] = body
    r = await client.request(method, "/hermes" + path, **kwargs)
    assert r.status in (200, 202)
    assert fake.seen[-1]["path"] == path
    if body is not None:
        assert json.loads(fake.seen[-1]["body"]) == body


async def test_telegram_sessions_stay_readable(make_client):
    client, fake, _ = await make_client()
    for path in (f"/api/sessions/{TELEGRAM_ID}", f"/api/sessions/{TELEGRAM_ID}/messages", "/api/sessions?source=telegram"):
        r = await client.get("/hermes" + path, headers=auth())
        assert r.status == 200
    assert [s["method"] for s in fake.seen] == ["GET", "GET", "GET"]


async def test_session_selection_headers_are_dropped(make_client):
    client, fake, _ = await make_client()
    r = await client.post("/hermes/v1/runs", json={"input": "hi"},
                          headers={**auth(), "X-Hermes-Session-Key": TELEGRAM_ID, "X-Hermes-Session-Id": TELEGRAM_ID})
    assert r.status == 202
    assert fake.seen[-1]["session_key"] is None and fake.seen[-1]["session_hdr"] is None


async def test_malformed_body_on_guarded_route_is_rejected(make_client):
    client, fake, _ = await make_client()
    r = await client.post("/hermes/v1/runs", data=b"not json", headers={**auth(), "Content-Type": "application/json"})
    assert r.status == 400
    assert (await r.json())["error"]["code"] == "invalid_json"
    assert fake.seen == []


async def test_job_delivery_defaults_to_local_only(make_client):
    client, fake, _ = await make_client()
    job = {"name": "n", "schedule": "every 1h", "prompt": "p"}
    r = await client.post("/hermes/api/jobs", json={**job, "deliver": "telegram"}, headers=auth())
    assert r.status == 403 and (await r.json())["error"]["code"] == "delivery_not_allowed"
    r = await client.patch("/hermes/api/jobs/0123456789ab", json={"deliver": "telegram"}, headers=auth())
    assert r.status == 403
    assert fake.seen == []
    r = await client.post("/hermes/api/jobs", json={**job, "deliver": "local"}, headers=auth())
    assert r.status == 200
    r = await client.post("/hermes/api/jobs", json=job, headers=auth())
    assert r.status == 200
    r = await client.post("/hermes/api/jobs/0123456789ab/pause", json={}, headers=auth())
    assert r.status == 200


async def test_job_delivery_can_be_widened_deliberately(make_client):
    client, fake, _ = await make_client(jobs__allowed_deliver=["local", "telegram"])
    r = await client.post("/hermes/api/jobs", json={"name": "n", "schedule": "every 1h", "prompt": "p", "deliver": "telegram"},
                          headers=auth())
    assert r.status == 200
    assert json.loads(fake.seen[-1]["body"])["deliver"] == "telegram"


def test_allowed_deliver_is_validated(tmp_path):
    base = {"proxy": {"hermes_env_file": "/x"}, "devices": [{"name": "a", "token_sha256": "a" * 64}]}
    assert hp.config_from_dict(base).allowed_deliver == ("local",)
    for bad in ("local", ["Local Disk"], [1], ["x" * 65]):
        with pytest.raises(ValueError):
            hp.config_from_dict({**base, "jobs": {"allowed_deliver": bad}})


def test_guard_is_a_pure_function():
    assert hp.guard_violation("GET", f"/api/sessions/{TELEGRAM_ID}", None) is None
    assert hp.guard_violation("POST", "/v1/runs", b'{"input":"x","session_id":"ios_ab"}') is None
    assert hp.guard_violation("POST", "/v1/runs", b'{"input":"x","session_id":"telegram:1"}')[1] == "session_read_only"
    assert hp.guard_violation("POST", "/v1/runs", b"[]")[1] == "invalid_json"
    assert hp.guard_violation("POST", "/v1/runs/run_1/stop", b"{}") is None
    assert hp.guard_violation("POST", "/v1/runs/run_1/approval", b'{"choice":"once"}') is None
