# Brainbox Agent Protocol — v1

The contract between the Brainbox Agent iOS app and any backend. A backend
implements this by running a **Brainbox gateway**: a small WebSocket server
that speaks this protocol on one side and the agent's native interface on the
other (see [HERMES_INTEGRATION.md](HERMES_INTEGRATION.md)).

The reference implementation of the client side lives in
`Packages/BrainboxCore/Sources/BrainboxCore/Protocol/WireProtocol.swift` and
`Transport/GatewayConnection.swift`. Every frame type below is exercised by the
core test-suite (`GatewayConnectionTests`, `WireProtocolTests`) against an
in-memory fake gateway, so this document and the code cannot silently drift.

---

## 1. Transport

| | |
|---|---|
| Primary transport | WebSocket, **text frames**, UTF-8 JSON, one envelope per frame |
| URL | Anything the user configures, e.g. `wss://brainbox.<tailnet>.ts.net/v1/agent` |
| TLS | `wss://` required. `ws://` is accepted by the app **only** for private hosts (Tailscale `100.64.0.0/10`, `*.ts.net`, RFC1918, loopback) |
| Subprotocol header | Client sends `Sec-WebSocket-Protocol: brainbox.v1` (gateways may ignore it) |
| Max frame | 8 MiB (client limit) |
| Heartbeat | Client sends `ping` every `heartbeatSeconds` (from `auth.ok`, default 20 s). A failed send closes the socket and triggers reconnect |
| HTTPS | Not required by v1. A gateway may additionally expose `GET /v1/health` for monitoring; the app does not depend on it |

## 2. Envelope

Every frame, in both directions:

```json
{
  "v": 1,
  "type": "message.delta",
  "id": "evt_6f0c…",
  "requestId": "3b1d4c3e-…",
  "conversationId": "a8e2…",
  "ts": "2026-10-08T04:38:00.123Z",
  "payload": { }
}
```

| Field | Type | Notes |
|---|---|---|
| `v` | int | Protocol version. The client rejects frames whose `v` ≠ 1 |
| `type` | string | Frame type (tables below) |
| `id` | string | **Event ID**, unique per frame (`evt_` + UUID recommended) |
| `requestId` | string? | Lower-case UUID. Present on every frame that belongs to a request |
| `conversationId` | string? | Lower-case UUID. Present on agent message frames |
| `ts` | string | ISO-8601 with or without fractional seconds (numbers = Unix seconds are also accepted) |
| `payload` | object | Type-specific |

Unknown `type`s are ignored by the client (forward compatible). Unknown
payload fields are ignored.

## 3. Lifecycle

```
client                                   gateway
  │── open WebSocket ───────────────────────▶│
  │── auth.hello {token,…} ─────────────────▶│
  │◀──────────── auth.ok {session, agent, capabilities, heartbeatSeconds}
  │                                          │
  │── message.send (requestId R) ───────────▶│
  │◀──────────── request.accepted (R)        │
  │◀──────────── agent.status (R) thinking   │
  │◀──────────── tool.started / tool.output / tool.finished (R) …
  │◀──────────── message.delta (R) …         │
  │◀──────────── conversation.title (R)      │  (optional)
  │◀──────────── message.completed (R)       │  ← terminal
  │                                          │
  │── ping ─────────────────────────────────▶│
  │◀──────────── pong                        │
```

### 3.1 Authentication — `auth.hello` → `auth.ok` | `auth.error`

The **first** frame after the socket opens must be `auth.hello`; the gateway
must not process anything else before it.

`auth.hello` payload:

```json
{
  "token": "<bearer token from the iOS Keychain>",
  "client": "brainbox-agent-ios",
  "clientVersion": "0.1.0 (1)",
  "platform": "ios",
  "protocolVersion": 1,
  "resumeSession": "sess_…"
}
```

`resumeSession` is sent when reconnecting, with the `session` from the last
`auth.ok`. Gateways may use it to re-attach subscriptions; they may also ignore
it.

`auth.ok` payload:

```json
{
  "session": "sess_123",
  "agent": { "id": "hermes", "name": "Hermes", "version": "x.y" },
  "capabilities": ["streaming", "cancellation", "toolExecution", "conversationHistory",
                   "terminal", "fileSystem", "serverMetrics", "serviceControl", "logs"],
  "heartbeatSeconds": 20
}
```

Capabilities drive the UI: anything not advertised is hidden or disabled.

`auth.error` payload is an [error payload](#5-errors) (`code: "auth_failed"`).
The client **does not retry** after an authentication failure — it shows
"Authentication failed" and waits for the user to fix the token.

Timeout: if `auth.ok` doesn't arrive within the connect timeout (15 s) the
client closes the socket and backs off.

## 4. Frame types

### 4.1 Client → gateway

| type | requestId | payload | meaning |
|---|---|---|---|
| `auth.hello` | – | see §3.1 | authenticate |
| `message.send` | ✓ | `{ "content": string, "responseMessageId": uuid }` | user message in `conversationId` |
| `request.cancel` | ✓ (of the request to cancel) | `{}` | stop generation / interrupt |
| `rpc.call` | ✓ | `{ "method": string, "params": object }` | one-shot call, see §6 |
| `stream.subscribe` | ✓ | `{ "method": string, "params": object }` | long-lived stream, see §7 |
| `stream.unsubscribe` | ✓ (of the subscription) | `{}` | end a subscription |
| `ping` | – | `{}` | heartbeat |

### 4.2 Gateway → client (agent messages)

All carry the `requestId` of the `message.send` they answer.

| type | payload | client effect |
|---|---|---|
| `request.accepted` | `{}` | request is queued/started |
| `agent.status` | `{ "state": "ready" \| "thinking" \| "streaming" \| "tool" \| "offline" \| "unavailable", "tool"?: string, "reason"?: string }` | status indicator & orb. Also valid **without** `requestId` for global status |
| `message.delta` | `{ "text": string }` | append text (markdown) to the reply — render immediately |
| `tool.started` | `{ "toolCallId": string, "kind": ToolKind, "name": string, "title": string, "input": string }` | insert a tool card at the current position in the reply |
| `tool.output` | `{ "toolCallId": string, "chunk": string }` | stream tool output into the card |
| `tool.finished` | `{ "toolCallId": string, "status": "succeeded" \| "failed" \| "cancelled", "output": string, "exitCode"?: int, "isError"?: bool, "truncated"?: bool }` | close the card |
| `conversation.title` | `{ "title": string }` | rename the conversation |
| `message.completed` | `{}` | **terminal** — reply finished |
| `error` | error payload | **terminal** — reply failed |

`ToolKind` is one of `terminal, file, search, browser, code, system, service,
git, network, other`. Unknown kinds render as `other`.

Ordering rules:

1. `request.accepted` first, then any number of the others, then exactly one
   terminal frame (`message.completed` or `error`).
2. `tool.output`/`tool.finished` must reference a `toolCallId` from an earlier
   `tool.started` in the same request.
3. Text and tools may interleave freely; the app renders them in arrival order.

### 4.3 Cancellation

The client sends `request.cancel` with the request's `requestId`. The gateway
should stop the agent and answer with a terminal `error` whose code is
`cancelled` (or `message.completed`). The client also ends the request locally
right away, so a slow gateway can't leave the UI stuck. Late frames for a
finished request are ignored.

## 5. Errors

```json
{ "code": "permission_denied", "message": "Path is outside exposed roots", "retryable": false }
```

| code | shown as |
|---|---|
| `auth_failed` / `unauthorized` | Authentication failed |
| `agent_unavailable` | Agent unavailable |
| `server_unavailable` | Server unavailable |
| `permission_denied` / `forbidden` | Permission denied |
| `not_found` | File unavailable |
| `conflict` | File changed on server (optimistic-concurrency failure) |
| `timeout` | Request timed out |
| `cancelled` | Cancelled |
| `not_implemented` | Not available yet |
| `command_failed` | Command failed |
| anything else | "Agent error" with the gateway's message and code |

## 6. RPC methods (`rpc.call` → `rpc.result` | `error`)

`rpc.result` payload: `{ "result": <value> }`. Models are the Codable structs
in `BrainboxCore/Models` serialised with ISO-8601 dates.

| method | params | result |
|---|---|---|
| `conversations.list` | `{}` | `[ConversationSummary]` |
| `tool.execute` | `ToolInvocation` | `ToolResult` |
| `vps.info` | `{}` | `ServerInfo` |
| `vps.metrics` | `{}` | `ServerMetrics` |
| `vps.services` | `{}` | `[ServiceStatus]` |
| `vps.processes` | `{}` | `[ProcessEntry]` |
| `vps.service.action` | `{ "name": string, "action": "start" \| "stop" \| "restart" }` | `ServiceStatus` |
| `terminal.open` | `{}` | `TerminalSession` |
| `terminal.close` | `{ "sessionId": uuid }` | `null` |
| `terminal.interrupt` | `{ "sessionId": uuid }` | `null` |
| `fs.roots` | `{}` | `[FileEntry]` — **only paths the gateway allows** |
| `fs.list` | `{ "path" }` | `[FileEntry]` |
| `fs.read` | `{ "path" }` | `FileContent` (`version` = etag/mtime/hash) |
| `fs.write` | `{ "path", "text", "expectedVersion"? }` | `FileContent` — must return `conflict` if `expectedVersion` doesn't match |
| `fs.createFile` / `fs.createDirectory` | `{ "path" }` | `FileEntry` |
| `fs.rename` | `{ "path", "newName" }` | `FileEntry` |
| `fs.delete` | `{ "path" }` | `null` |
| `fs.search` | `{ "query", "path" }` | `[FileEntry]` |
| `logs.recent` | `{ "limit" }` | `[LogEntry]` |

Client timeout for RPC: 45 s → `timeout` error.

## 7. Streams (`stream.subscribe` → `stream.data`* → `stream.end` | `error`)

`stream.data` payload is one value; `stream.end` is terminal.

| method | params | each `stream.data` |
|---|---|---|
| `vps.metrics` | `{ "intervalSeconds": number }` | `ServerMetrics` |
| `logs.stream` | `{ "categories": [LogCategory] }` | `LogEntry` |
| `terminal.run` | `{ "sessionId": uuid, "command": string }` | `{ "stream": "stdout" \| "stderr", "data": string }` or `{ "stream": "exit", "code": int }` |

When the client stops listening it sends `stream.unsubscribe`; the gateway must
stop the underlying work (for `terminal.run`, that means sending SIGINT /
killing the process).

## 8. Reconnection semantics

* Any unexpected socket close → every in-flight request/RPC/stream fails on the
  client with `webSocketDisconnected`. **Nothing is replayed automatically** —
  a half-run command must never run twice.
* The client reconnects with exponential backoff (0.5 s × 2ⁿ, ±25 % jitter,
  capped at 30 s), immediately on app foreground or when the network returns,
  and never after `auth_failed`.
* On reconnect it re-sends `auth.hello` with `resumeSession`.

## 9. Security requirements for gateways

* Listen only on a private interface (Tailscale) or behind TLS + auth.
* Compare tokens in constant time; rotate them; never log them.
* Enforce an allow-list of file roots server-side (`fs.*`) and normalise paths
  (`..`) before checking.
* Treat `vps.service.action`, `fs.write`, `fs.delete`, `terminal.*` as
  privileged; log them (without secrets).
* Rate-limit `auth.hello`.

## 10. Versioning

Additive changes (new frame types, new optional fields, new capabilities) keep
`v: 1`. Breaking changes bump `v`; the client refuses frames with a different
version and shows "Unexpected response".
