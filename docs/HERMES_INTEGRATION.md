# Hermes integration plan

**Status: pending.** No part of this repository talks to Hermes. No Hermes
endpoint, message format, port, or authentication scheme has been assumed or
invented. `HermesProvider` exists only as a clearly-marked placeholder that
reports *"pending integration"* and is disabled in the UI.

This document lists exactly what we need to learn from the real Hermes
installation, and how the integration will be built once we have it.

---

## 1. Target architecture

```
┌──────────────┐  Brainbox Agent Protocol v1   ┌──────────────────────────────┐  Hermes' own interface   ┌────────┐
│ Brainbox iOS │ ───── wss over Tailscale ───▶ │ Brainbox Gateway (on the VPS) │ ───── (to be inspected) ─▶│ Hermes │
│  app         │ ◀──── streamed events ─────── │  └─ Hermes adapter           │ ◀────────────────────────  │        │
└──────────────┘                               │  └─ VPS / files / logs module │                           └────────┘
                                               └──────────────────────────────┘
```

* The **app never talks to Hermes directly.** It keeps using
  `RemoteAgentProvider` (already implemented and tested).
* The **gateway** is a new, small service that we will write and run next to
  Hermes. It implements [AGENT_PROTOCOL.md](AGENT_PROTOCOL.md) and translates:
  * Brainbox `message.send` → Hermes request
  * Hermes output / tool activity → Brainbox `message.delta`, `tool.*`, `agent.status`
  * `request.cancel` → whatever Hermes offers for interruption (or process signal)
* VPS metrics, files, terminal and logs are served by the gateway itself (from
  the OS), not by Hermes, so they work even when Hermes is down.

Why a gateway instead of pointing the app at Hermes:

1. Hermes is not assumed to be an HTTP/WebSocket server at all.
2. Hermes' interface can change without an app update — only the adapter changes.
3. Auth, file-root allow-lists, rate limits and audit logging live in one
   place we control, on the private network.
4. The installation on the VPS is not modified; the gateway is additive.

`HermesProvider` (on-device adapter) is kept only as a fallback design in case
inspection shows on-device translation is preferable. Expectation: we will
**not** need it.

## 2. What we must find out (inspection checklist)

Run these **read-only** checks on the VPS when we're ready. Nothing here
changes the installation.

| # | Question | Why it matters | How we'll check |
|---|---|---|---|
| 1 | How is Hermes started? (systemd unit, docker, screen, script) | Where the adapter attaches; restart semantics | `systemctl list-units`, `docker ps`, `ps aux` |
| 2 | What interfaces does it expose? (CLI, local HTTP/WS API, Unix socket, messaging bots such as Telegram, library import) | Determines adapter type | its docs/README, config files, `ss -lntp` |
| 3 | Does it stream output token-by-token? In what format? | Maps to `message.delta` | docs / a test request |
| 4 | Does it expose tool/command activity (start, output, finish, exit code)? | Maps to `tool.*` cards | logs / API events |
| 5 | Conversation/session model: ids, history, persistence | Maps `conversationId`, `conversations.list` | docs / data dir |
| 6 | How can a running task be interrupted? | Maps `request.cancel` | docs / signals |
| 7 | Authentication on its existing interfaces | Gateway → Hermes credentials | config (values never copied into this repo) |
| 8 | Where does it log? | `logs.stream` category `agent` | config / journald |
| 9 | Resource limits / concurrency | Gateway queueing | config |
| 10 | Which filesystem paths should the app see? | `fs.roots` allow-list | decided with you |

## 3. Requirements for the adapter (once facts are known)

| Area | Requirement |
|---|---|
| Endpoint | Gateway listens on the VPS Tailscale IP (or `tailscale serve` HTTPS) at e.g. `wss://<host>.<tailnet>.ts.net/v1/agent`. Not exposed on the public interface |
| Authentication | Bearer token in `auth.hello`, stored in the iOS Keychain; gateway stores only a hash; constant-time compare; optional Tailscale identity check as a second factor |
| WebSocket | Text frames, protocol v1, heartbeat ≤ 30 s, handles `resumeSession` |
| Message format | Exactly as AGENT_PROTOCOL §4.2 |
| Streaming format | Every chunk Hermes produces becomes one `message.delta`; no buffering of whole replies |
| Tool events | Hermes tool/command activity → `tool.started` / `tool.output` / `tool.finished` with real exit codes; unknown activity → `kind: other` |
| Conversations | Map Hermes sessions ↔ Brainbox `conversationId` (store the mapping in the gateway) |
| File access | Gateway-enforced allow-list, path normalisation, `version` = mtime+size hash for conflict detection, read-only areas respected |
| Terminal | Gateway-owned PTY sessions under a dedicated low-privilege user; `terminal.interrupt` sends SIGINT |
| Server control | `vps.service.action` limited to an allow-listed set of systemd units via a narrow sudoers rule |
| Agent status | Map Hermes busy/idle into `agent.status` (global frames without `requestId`) |
| Errors | Hermes failures → `error` frames with the codes in AGENT_PROTOCOL §5 |

## 4. Possible adapter shapes (decide after inspection)

1. **API adapter** — Hermes exposes a local HTTP/WebSocket API: gateway calls it
   over localhost and translates events. Cleanest option.
2. **CLI adapter** — Hermes is driven via a command: gateway spawns it per
   request and parses stdout as a stream. Cancellation = signal.
3. **Library adapter** — Hermes is importable (e.g. Python package): gateway
   (written in the same language) calls it in-process.
4. **Bridge adapter** — Hermes only speaks through a messaging integration:
   gateway acts as another client of that channel. Least preferred.

## 5. Integration procedure

1. Inspect (checklist §2) — read-only.
2. Pick the adapter shape; write the gateway (separate repo or `gateway/`
   folder), with its own tests using recorded Hermes output.
3. Run the gateway as a systemd service on the Tailscale interface; create the
   token; put the token and URL into the app (Settings → Connection).
4. Select **Remote Agent** in the app. The UI does not change.
5. Only after it works end-to-end: rename the provider label to "Hermes" in the
   app (the `hermes` provider kind can then become an alias of `remote`).
6. Claim compatibility only for the Hermes version actually tested.

## 6. What will be needed from you

* SSH/Tailscale access to the VPS for the read-only inspection (or the outputs
  of the commands in §2).
* Which folders the app may browse/edit.
* Which services the app may start/stop.
* Whether the terminal should be enabled at all, and as which Unix user.
