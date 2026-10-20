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

## Step 0 — Back up (2 min)

```bash
sudo cp -a /root/.hermes/.env /root/.hermes/.env.bak-$(date +%F)
sudo cp -a /root/.hermes/config.yaml /root/.hermes/config.yaml.bak-$(date +%F)
systemctl status hermes-gateway --no-pager | head -5   # note it's active
```

## Step 1 — Enable the Hermes API server (loopback only)

Hermes ships an API server that is **off by default**. Turn it on, bound to
loopback, with a strong key. Append to `/root/.hermes/.env`:

```bash
KEY=$(openssl rand -hex 32)
sudo tee -a /root/.hermes/.env >/dev/null <<EOF
API_SERVER_ENABLED=true
API_SERVER_HOST=127.0.0.1
API_SERVER_PORT=8642
API_SERVER_KEY=$KEY
EOF
unset KEY
sudo chmod 600 /root/.hermes/.env
```

Don't set `API_SERVER_CORS_ORIGINS` (the app isn't a browser). Never bind to
`0.0.0.0`, and never publish port 8642.

## Step 2 — Restart Hermes once (your decision, your timing)

The API server starts with the Hermes gateway process, so this one restart
is unavoidable. **It briefly disconnects the Telegram bot (a few seconds);**
pending Telegram updates are delivered when it reconnects. Pick a quiet
moment:

```bash
sudo systemctl restart hermes-gateway
sleep 5
systemctl is-active hermes-gateway                  # → active
journalctl -u hermes-gateway -n 50 --no-pager | grep -iE "telegram|api.server|error"
```

Check Telegram still replies (send your bot a message). Then check the API:

```bash
KEY=$(sudo grep ^API_SERVER_KEY= /root/.hermes/.env | cut -d= -f2-)
curl -s http://127.0.0.1:8642/health
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:8642/v1/capabilities | head -c 600; echo
unset KEY
```

**Rollback:** restore `.env.bak-*` and restart again. Nothing else changed.

## Step 3 — Install the Brainbox proxy (starts nothing)

From a checkout of this repo on the VPS:

```bash
sudo ./gateway/deploy/install.sh
```

It installs into `/opt/brainbox-gateway/venv` with the `[proxy]` extra,
copies `hermes-proxy.example.toml` → `/etc/brainbox-gateway/hermes-proxy.toml`
(mode 600) and the `brainbox-hermes-proxy.service` unit. It does **not**
enable or start anything, and doesn't touch Hermes.

## Step 4 — Create a device token for your iPhone

```bash
sudo /opt/brainbox-gateway/venv/bin/brainbox-gateway new-device --name "David's iPhone"
```

It prints the **token** (shown once — this goes into the app) and its
**sha256**. Put only the sha256 into `/etc/brainbox-gateway/hermes-proxy.toml`
under `[[devices]]`, replacing the placeholder. Keep `admin = false` unless
you want the phone to create Hermes profiles (also needs
`[profiles] admin_enabled = true`).

Validate (it refuses the placeholder, wrong permissions, a missing key, or a
non-loopback Hermes URL):

```bash
sudo /opt/brainbox-gateway/venv/bin/brainbox-gateway hermes-proxy-check --config /etc/brainbox-gateway/hermes-proxy.toml
```

## Step 5 — Start the proxy

```bash
sudo systemctl enable --now brainbox-hermes-proxy
systemctl is-active brainbox-hermes-proxy
curl -s -H "Authorization: Bearer <device token>" http://127.0.0.1:8766/hermes/brainbox/info
```

This service is independent of `hermes-gateway`: restarting or stopping it
never touches Hermes or Telegram.

## Step 6 — Publish privately over Tailscale

The VPS needs Tailscale (the earlier inspection found none — install it and
join your tailnet first, and install Tailscale on the iPhone). Then:

```bash
sudo tailscale serve --bg --https=8444 http://127.0.0.1:8766
tailscale serve status
```

Use `serve`, **not** `funnel` — funnel would put it on the public internet.

## Step 7 — Connect the app

Settings → **Hermes**:

1. URL: `https://<vps-host>.<tailnet>.ts.net:8444/hermes`
2. Device token: the token from step 4 (stored in the iPhone Keychain only)
3. **Test connection** — the app reads `/v1/capabilities` and shows which
   features your server supports. Only a fully compatible result shows the
   “Hermes connected” sheet.
4. **Use Hermes as the backend.**

Your Telegram conversations appear under Chat → **All sessions** as
**read-only** transcripts. “Continue in app” makes an explicit fork into a
separate `ios_…` session; replies never go to Telegram.

## Revoking a phone

Delete its `[[devices]]` entry, then `sudo systemctl restart brainbox-hermes-proxy`.

## Turning it all off

```bash
sudo systemctl disable --now brainbox-hermes-proxy
sudo tailscale serve --https=8444 off
# optional: remove the API_SERVER_* lines from /root/.hermes/.env and restart hermes-gateway
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
| `/api/sessions` (+ messages, fork) | Session browser, Telegram transcripts, fork-to-continue | **yes** |
| `POST /v1/runs/{id}/approval` | Approval sheet | optional |
| `POST /v1/runs/{id}/steer` | Steer a running agent | optional |
| `POST /v1/runs/{id}/stop` | Stop button | optional |
| `/api/jobs` | Scheduled jobs (501 if cron is unavailable → hidden) | optional |
| `/v1/skills`, `/v1/toolsets`, `/v1/models` | Capabilities screen | optional |
| `/p/<profile>/…` (multiplex) | Teammate ↔ Hermes profile routing | optional, off by default |

Verified against Hermes source at commit 284d220 (route table and run-event
names). **Not yet verified against your live VPS** — Test connection is that
verification.
