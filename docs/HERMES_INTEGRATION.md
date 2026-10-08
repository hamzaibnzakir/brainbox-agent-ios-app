# Hermes integration

**Status: gateway built and tested; Hermes adapter waiting for one
verification run on the VPS.** Until `hermes.verified = true` the gateway
refuses to call Hermes, so nothing is ever claimed to work before it's proven
on your install.

---

## 1. What the inspection found (Hermes Agent v0.21.2, 2026-10-08)

| Fact (from the read-only inspection) | Consequence |
|---|---|
| Installed from git at `/opt/hermes-src`, venv `/opt/hermes-src/venv`, Python 3.11.16 | Gateway's Hermes worker runs with that interpreter |
| Config/keys in `HERMES_HOME=/root/.hermes`; runs as **root** via `hermes-gateway.service` | Gateway must run as root to use the same Hermes (see §5) |
| Hermes exposes **no** HTTP, WebSocket, TCP or Unix-socket API | The app can't talk to Hermes directly — a gateway is required |
| Interfaces: CLI (`hermes chat`, …), Telegram bot (long-polling), internal library | Gateway uses the library (preferred) or CLI |
| No structured event stream; logs go to journald | Tool cards depend on library callbacks (to be confirmed) |
| No Tailscale on the VPS | Private exposure needs a decision (§4) |
| Telegram session ids look like `agent:main:telegram:dm:<chat_id>` | App chats get **separate** gateway-managed history; the Telegram DM session is never reused |

### Corrections to the inspection report

1. **Hermes has a documented Python library API.** The report called the
   Python module "internal / not designed for embedding", but the official
   docs ("Using Hermes as a Python Library") document
   `from run_agent import AIAgent`, `AIAgent(quiet_mode=True, …)` and
   `run_conversation(user_message, conversation_history=…)` returning
   `final_response` and `messages`, with caller-managed history and "one
   AIAgent per thread". That is a cleaner integration than piping
   `hermes chat`, so it's the gateway's default.
2. **Cancellation must not use `hermes gateway stop` / `systemctl stop`.**
   That stops the whole `hermes-gateway.service`, i.e. your Telegram bot. The
   gateway runs each app turn in its own worker process group and kills only
   that group.
3. The report's "`tool.started → tool.output → tool.finished` lifecycle" are
   the Brainbox protocol's own frame names, not Hermes events. Hermes'
   callback names are **not documented**; the probe reads the real signature.
4. "Existing Telegram integration already uses CLI under the hood" and
   "Can pipe/output JSON if needed" are unverified claims and are not relied on.

## 2. Architecture

```
iPhone ── wss (Tailscale) ──▶ Brainbox Gateway  (brainbox-gateway.service, separate from Hermes)
                              ├─ chat ──▶ worker process (Hermes' venv python)
                              │            from run_agent import AIAgent → run_conversation(...)
                              │            · one process per turn · cancel = kill that process group
                              │            · history stored by the gateway per app conversation
                              ├─ VPS metrics / processes   (psutil, read-only)
                              ├─ services                   (systemctl, allow-list only)
                              ├─ logs                       (journalctl -u <allow-listed>, read-only)
                              ├─ files                      (sandboxed roots, conflict detection)
                              └─ terminal                   (off by default)
hermes-gateway.service (Telegram) keeps running untouched.
```

Code: `gateway/` (Python 3.10+, depends on `websockets` and `psutil`).

| Module | Role |
|---|---|
| `server.py` | Protocol v1 server: auth, multiplexing, cancel, RPC, streams |
| `adapters.py` | `EchoAdapter` (link test), `HermesLibraryAdapter` (default), `HermesCLIAdapter` (fallback) |
| `hermes_worker.py` | Runs one turn via `AIAgent`; stdout = JSON events only; stdin closed so approval prompts can't hang |
| `files.py`, `system.py`, `terminal.py` | Sandboxed system features |
| `tools/probe_hermes.py` | **Read-only** verification of the real Hermes API |

### Streaming and tool cards

* If the installed `AIAgent` has a streaming callback parameter, deltas stream
  live; otherwise the gateway releases the final answer in small chunks (the
  app still animates, but output appears when Hermes finishes).
* If it has a tool-progress callback, tool cards appear; otherwise none.
* The worker only passes a callback whose parameter name actually exists in
  the installed signature. The probe output tells us which applies.

### Dangerous commands

The worker closes stdin, so if Hermes would ask for interactive approval it
cannot block forever; how Hermes treats "no answer" (deny vs error) is shown by
the probe's approval grep and will be confirmed in the live test.
`allow_dangerous_commands` stays `false` (the CLI fallback would add `--yolo`
only if you turn it on).

## 3. Verification (run on the VPS, read-only)

```bash
# copy gateway/tools/probe_hermes.py to the VPS, then:
/opt/hermes-src/venv/bin/python probe_hermes.py          # inspection only
/opt/hermes-src/venv/bin/python probe_hermes.py --live   # + one tiny prompt, memory off
```

It changes nothing (no config edits, no restarts, no Telegram, no secrets
printed). `--live` spends a few tokens. Paste the output back; based on it we
set `hermes.verified = true` (and adjust callback handling if needed).

## 4. Deployment (needs your decisions)

1. `sudo bash gateway/deploy/install.sh` — installs to `/opt/brainbox-gateway`,
   creates `/etc/brainbox-gateway/gateway.toml`, installs the systemd unit,
   **starts nothing**, touches nothing of Hermes.
2. `brainbox-gateway new-token` → paste the hash into the config, the token
   into the app (Settings → Connection).
3. Start with `adapter = "echo"`, connect the app, confirm the link.
4. After the probe passes: `adapter = "hermes"`, `verified = true`, restart
   **brainbox-gateway** (not hermes-gateway).

Exposure options:

| Option | Exposure | Notes |
|---|---|---|
| **Tailscale (recommended)** | Only your devices | Install Tailscale on VPS + iPhone; `tailscale serve --bg --https=8443 http://127.0.0.1:8765`; URL `wss://<host>.<tailnet>.ts.net:8443/v1/agent`. Port 8443 because nginx already uses 443 |
| nginx subdomain + TLS | Public internet, token-protected | Works with existing nginx, but a root-capable agent becomes reachable from anywhere. Not recommended |

## 5. Risks you should decide on

* **Root.** Hermes runs as root with its keys in `/root/.hermes`, so the gateway
  that drives it does too. Anyone holding the app token effectively controls a
  root-level agent. Mitigations built in: localhost bind, token hash only,
  rate-limited auth, file sandbox, service allow-list, terminal off. Strongly
  recommended: Tailscale-only exposure.
* **Shared memory.** `use_memory = true` lets app chats read/write Hermes'
  persistent memory (same as Telegram). Set `false` to keep them separate.
* **Concurrency.** App turns run in separate processes alongside the Telegram
  bot. The library docs say one `AIAgent` per thread; separate processes
  satisfy that, but shared files under `HERMES_HOME` (memory, skills) are
  written by both.
