# Connecting the app to Hermes (safe, manual VPS procedure)

This is the procedure for connecting Brainbox to **your existing Hermes Agent
(v0.21.2, commit 284d220)**. Every step is run **by you, by hand**. Nothing in
this repo, the app, or CI touches your VPS automatically.

> **What stays exactly as it is:** the Telegram bot, its token, its
> long-polling connection, `hermes-gateway.service`'s adapters, and
> `/root/.hermes/state.db`. The app never starts a second Telegram poller,
> never writes to the Telegram session, and never edits `state.db` — it only
> uses the Hermes HTTP API that Hermes itself ships.

---

## How it fits together

```
iPhone (Brainbox) ──HTTPS over Tailscale──▶ brainbox-hermes-proxy  (127.0.0.1:8766, path /hermes)
                                             · per-device tokens (SHA-256 stored, revocable)
                                             · route allow-list, rate limits, audit log
                                             · swaps in API_SERVER_KEY server-side
                                            ──▶ Hermes API Server (127.0.0.1:8642, built into Hermes)
                                                 └── same agent, sessions, skills, memory as Telegram
hermes-gateway.service  ── Telegram long-polling (unchanged)
```

The phone never sees `API_SERVER_KEY`. Lose the phone → delete its device
entry → done; no Hermes key rotation needed.

---

Run these as root over SSH, in order, and stop at any failed check. **Do
stages 4 and 6 yourself, not through the Hermes agent:** an agent that
restarts its own gateway kills itself mid-reply, and a device token printed
in a Telegram chat would end up in your chat history and `state.db`.

## Stage 0 — Preflight (read-only)

Stop if `API_SERVER_` lines already exist, or if `config.yaml` has an
`api_server` block that disables it.

```bash
systemctl is-active hermes-gateway                              # active
ss -ltnp | grep -E ':(8642|8766|8444)\b' || echo "ports free"     # ports free
stat -c '%a %U %n' /root/.hermes/.env                           # note mode
grep -c '^API_SERVER_' /root/.hermes/.env                       # 0
grep -n 'api_server' /root/.hermes/config.yaml || echo "no api_server block"
python3 --version && python3 -c 'import venv, ensurepip' && echo venv-ok   # 3.10+
command -v rsync git openssl curl
```

## Stage 1 — Backups

`state.db` is not copied because nothing touches it.

```bash
install -d -m 700 /root/brainbox-backup
TS=$(date +%F-%H%M)
cp -a /root/.hermes/.env        /root/brainbox-backup/hermes.env.$TS
cp -a /root/.hermes/config.yaml /root/brainbox-backup/config.yaml.$TS
```

## Stage 2 — Tailscale on the VPS

`--accept-dns=false` leaves `/etc/resolv.conf` alone, so Telegram's DNS is not
affected. No exit node, no subnet routes. In the Tailscale admin console → DNS,
turn on **MagicDNS** and **HTTPS Certificates**.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --accept-dns=false        # open the printed login URL and approve
tailscale status --self                # note the MagicDNS name: <vps-host>.<tailnet>.ts.net
```

## Stage 3 — API server settings (no effect until Stage 4)

At Hermes 284d220 the API server starts when a usable `API_SERVER_KEY`
(16+ characters, not a placeholder) is in the environment
(`gateway/config_env.py`, `_api_server`). The key is generated and appended
without ever being printed. Don't set `API_SERVER_CORS_ORIGINS`; never bind to
`0.0.0.0`.

```bash
umask 077
KEY="$(openssl rand -hex 32)"
printf '\n# Brainbox iOS: Hermes API server, loopback only (added %s)\nAPI_SERVER_HOST=127.0.0.1\nAPI_SERVER_PORT=8642\nAPI_SERVER_KEY=%s\n' "$(date -I)" "$KEY" >> /root/.hermes/.env
unset KEY
chmod 600 /root/.hermes/.env
grep -c '^API_SERVER_' /root/.hermes/.env                                          # 3
awk -F= '/^API_SERVER_KEY=/{print "key length:", length($2)}' /root/.hermes/.env   # 64
```

## Stage 4 — One Hermes restart (you, at a quiet moment)

The API server only starts with the gateway process (`/platform resume` only
re-queues platforms that were enabled at startup), so one restart is
unavoidable. It takes Telegram offline for a few seconds.

Send **`/restart`** to your bot in Telegram: Hermes drains running work,
restarts under systemd and confirms in the chat. Fallback over SSH:
`systemctl restart hermes-gateway`. Then:

```bash
systemctl is-active hermes-gateway                                   # active
ss -ltnp | grep ':8642'                                              # 127.0.0.1:8642 ONLY
curl -s http://127.0.0.1:8642/health; echo                           # status ok
KEY="$(awk -F= '/^API_SERVER_KEY=/{print $2}' /root/.hermes/.env)"
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:8642/v1/capabilities | python3 -m json.tool | head -40
unset KEY
journalctl -u hermes-gateway --since "-10 min" --no-pager | grep -iE "api.?server|telegram|error" | tail -20
```

Send your bot a normal Telegram message — it must reply as before.

## Stage 5 — Install the Brainbox proxy (starts nothing)

```bash
git clone --branch feature/hermes-ios https://github.com/hamzaibnzakir/brainbox-agent-ios-app /opt/brainbox-src
cd /opt/brainbox-src/gateway && git log -1 --oneline        # the reviewed commit
bash deploy/install.sh
```

`install.sh` installs into `/opt/brainbox-gateway/venv` with the `[proxy]`
extra, copies `hermes-proxy.example.toml` → `/etc/brainbox-gateway/hermes-proxy.toml`
(mode 600, only if missing) and installs both unit files. It enables or starts
nothing and doesn't touch Hermes.

## Stage 6 — Device token and proxy config (you, over SSH)

```bash
/opt/brainbox-gateway/venv/bin/brainbox-gateway new-device --name "David's iPhone"
# save the printed token in your password manager — it is shown once
nano /etc/brainbox-gateway/hermes-proxy.toml
```

Replace the example `[[devices]]` entry with the printed one. Keep
`admin = false`, `[profiles] multiplex = false`, `admin_enabled = false` and
`[jobs] allowed_deliver = ["local"]`. Then validate — it refuses the
placeholder hash, group/world-readable config or key files, a missing key, and
a non-loopback `hermes_url`:

```bash
/opt/brainbox-gateway/venv/bin/brainbox-gateway hermes-proxy-check --config /etc/brainbox-gateway/hermes-proxy.toml
# OK · listen=127.0.0.1:8766/hermes upstream=http://127.0.0.1:8642 devices=1 hermes_key=found multiplex=False profile_admin=False job_delivery=local
```

## Stage 7 — Start and check the proxy

```bash
systemctl enable --now brainbox-hermes-proxy
ss -ltnp | grep ':8766'                                         # 127.0.0.1:8766 ONLY
read -rs -p "Device token: " T; echo
curl -s -H "Authorization: Bearer $T" http://127.0.0.1:8766/hermes/brainbox/info; echo
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $T" http://127.0.0.1:8766/hermes/v1/capabilities   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8766/hermes/v1/capabilities                              # 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -d '{"title":"x"}' http://127.0.0.1:8766/hermes/api/sessions/not-an-app-session/fork                             # 403
unset T
```

This service is independent of `hermes-gateway`: restarting or stopping it
never touches Hermes or Telegram.

## Stage 8 — Publish inside your tailnet only

```bash
tailscale serve --bg --https=8444 http://127.0.0.1:8766
tailscale serve status            # https://<vps-host>.<tailnet>.ts.net:8444 -> http://127.0.0.1:8766
```

Use `serve`, **never** `funnel` — funnel would put it on the public internet.

## Stage 9 — Connect the app

Install Tailscale on the iPhone and sign in to the same tailnet. In Brainbox,
Settings → **Hermes**:

1. URL: `https://<vps-host>.<tailnet>.ts.net:8444/hermes` → **Save URL**
2. Device token from Stage 6 → **Save token** (Keychain only, this device)
3. **Test connection** — reads `/v1/capabilities`; only a compatible server
   shows the “Hermes connected” sheet
4. **Use Hermes now**

Your Telegram conversations appear under Chat → **All sessions** as
**read-only** transcripts. “Continue in the app” makes a local copy that
re-sends the transcript with each message (Hermes never stores that history)
in a separate `ios_…` session. The Telegram session is only read — never
forked, written or ended — and replies never go to Telegram. The proxy
enforces this too: it refuses any write to a session that isn't `ios_…`.

## Revoking a phone

Delete its `[[devices]]` entry, then `sudo systemctl restart brainbox-hermes-proxy`.

## Turning it all off

```bash
tailscale serve --https=8444 off
systemctl disable --now brainbox-hermes-proxy
# optional, to turn the Hermes API server off again (Telegram offline for a few seconds):
cp -a /root/brainbox-backup/hermes.env.<TS> /root/.hermes/.env    # then /restart in Telegram
# optional, remove the proxy completely:
rm -rf /opt/brainbox-gateway /etc/brainbox-gateway /etc/systemd/system/brainbox-*.service && systemctl daemon-reload
```

---

## Safety notes

* **Terminal access stays disabled** in the Brainbox gateway until the first
  end-to-end test has been done by you. The Hermes agent itself can still run
  tools (including shell) exactly as it does from Telegram, subject to Hermes'
  own dangerous-command approvals — which the app shows as an approval sheet
  (once / session / always / deny; “always” requires an extra confirmation).
* The proxy forwards only an allow-list of routes (runs, run events/status/
  stop/steer/approval, sessions, jobs, capabilities, models, skills,
  toolsets, health). Everything else is 404.
* **Session guard:** through the proxy the app can only create, change, fork,
  chat in or run against its own `ios_…` sessions. Writes to any other session
  (Telegram included) are refused with 403 before reaching Hermes and are
  written to the audit log. `X-Hermes-Session-*` headers are dropped, and
  `previous_response_id` is refused, so a run can't be steered into another
  session. Job delivery is limited to `[jobs] allowed_deliver` (default `local`).
* `hermes.verified` in the older WebSocket gateway stays `false` until you have
  reviewed the probe output yourself — this proxy path doesn't change that.
* Hermes profiles are **configuration presets, not sandboxes**: they share the
  machine and user.

## Compatibility matrix (Hermes API Server → app feature)

Determined by the app at connect time from `/v1/capabilities`; anything
missing is turned off in the UI instead of failing later.

| Hermes API | App feature | Required? |
|---|---|---|
| `POST /v1/runs` | Send a message / teammate run | **yes** |
| `GET /v1/runs/{id}/events` (SSE) | Live streaming text, tool cards, reasoning | **yes** |
| `GET /v1/runs/{id}` | Recovery after disconnect (polling) | **yes** |
| `/api/sessions` (+ messages) | Session browser, read-only Telegram transcripts, copy-to-continue | **yes** |
| `POST /v1/runs/{id}/approval` | Approval sheet | optional |
| `POST /v1/runs/{id}/steer` | Steer a running agent | optional |
| `POST /v1/runs/{id}/stop` | Stop button | optional |
| `/api/jobs` | Scheduled jobs (501 if cron is unavailable → hidden) | optional |
| `/v1/skills`, `/v1/toolsets`, `/v1/models` | Capabilities screen | optional |
| `/p/<profile>/…` (multiplex) | Teammate ↔ Hermes profile routing | optional, off by default |

Verified against Hermes source at commit 284d220 (route table and run-event
names). **Not yet verified against your live VPS** — Test connection is that
verification.
