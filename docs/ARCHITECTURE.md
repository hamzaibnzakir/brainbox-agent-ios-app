# Architecture

```
┌──────────────────────────── BrainboxAgent (SwiftUI app, iOS 17+) ────────────────────────────┐
│ Features        Home · Agent (chat) · VPS (metrics, services, terminal, logs, processes)      │
│                 Files (browser, editor, diff) · Settings (connection, agent, security, dev)   │
│ App layer       AppModel ─ owns ProviderSuite, connection/status observation, scene phase    │
│                 ChatStore ─ conversations, streaming, stop/retry, persistence                 │
│                 BiometricGate (LocalAuthentication) · NetworkMonitor (NWPath) · AppSettings   │
│ Design system   Theme (tokens) · Motion (springs, stagger, transitions) · AgentOrb · components│
└───────────────────────────────────────────────┬──────────────────────────────────────────────┘
                                                │ protocols only
┌────────────────────────── BrainboxCore (Swift package, builds on iOS/macOS/Linux) ───────────┐
│ Providers/Protocols   AgentProvider · VPSProvider · TerminalProvider · FileSystemProvider     │
│                       LogStreamProvider · ProviderSuite                                       │
│ Providers/Mock        MockAgentProvider (scripted scenarios) · MockVPS · MockTerminal (shell) │
│                       MockFileSystem (allow-listed roots) · MockLogs                          │
│ Providers/Remote      RemoteAgent/VPS/Terminal/Files/Logs → GatewayConnection                 │
│ Providers/Hermes      HermesProvider — PENDING, throws notImplemented                         │
│ Protocol              WireEnvelope · WireCodec (events ↔ frames) · JSONValue                  │
│ Transport             WebSocketTransport (URLSession / in-memory) · GatewayConnection         │
│                       (auth, multiplexing by requestId, RPC, streams, heartbeat, backoff)     │
│ Chat                  ChatReducer (events → message) · MessageSegment (inline tool cards)     │
│ Security              CredentialStore (Keychain / in-memory) · SecurityPolicy · validators    │
│ Persistence           FileConversationStore · JSONFileCache (offline snapshots)               │
│ Text                  MarkdownParser · SyntaxHighlighter · LineDiff · ConfigValidator         │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Key decisions

**Provider abstraction.** The UI only knows `AgentProvider` and friends.
Swapping Mock → Remote → (future) Hermes is `AppModel.rebuildSuite()`
replacing one `ProviderSuite`; no view changes. Capabilities advertised by the
provider decide which surfaces are enabled.

**Gateway, not direct Hermes.** The app speaks one protocol
([AGENT_PROTOCOL.md](AGENT_PROTOCOL.md)) to a gateway. Backend-specific
translation happens server-side ([HERMES_INTEGRATION.md](HERMES_INTEGRATION.md)).

**One event model.** Every provider emits `AgentEvent`s (`accepted`, `status`,
`textDelta`, `toolStarted/Output/Finished`, `conversationTitle`, `completed`,
`failed`). `ChatReducer` applies them to a `Message`; it's pure and unit
tested. Tool calls are anchored inside the message text with an invisible
marker so cards render exactly where they happened (`MessageSegment`).

**Core is platform-neutral.** `BrainboxCore` has no UIKit/SwiftUI and guards
Apple-only APIs, so ~60 tests run on cheap Linux runners on every push, and
again on macOS.

**Generated project.** `project.yml` (XcodeGen) is the source of truth; the
`.xcodeproj` is generated in CI and git-ignored. No merge conflicts in project
files, and the build works on any macOS runner.

## Concurrency

* App state types are `@MainActor @Observable`.
* Providers expose `AsyncThrowingStream`s; cancelling the consuming task
  cancels the work (mock tasks are cancelled, remote sends `request.cancel` /
  `stream.unsubscribe`).
* `Broadcaster` multicasts connection/status state with replay-latest.
* `GatewayConnection` keeps mutable state behind a lock and uses a
  `generation` counter so callbacks from a dead socket can't touch a new one.

## Connection lifecycle (remote)

```
disconnected → connecting → (auth.hello/auth.ok) → connected
connected ──socket drop──▶ reconnecting(attempt n, delay) ──▶ connected
                   in-flight requests fail with webSocketDisconnected (never replayed)
auth error ─────────────▶ failed(authenticationFailed)   (no retry)
app foreground / network back ─▶ reconnectNow() (skips remaining backoff)
```

## Offline behaviour

* Conversations are persisted per conversation (JSON, file protection
  `completeUntilFirstUserAuthentication`) and always readable.
* The last server snapshot (info, metrics, services) is cached and shown with a
  **Cached** badge until live data arrives.
* Sending while offline marks the reply *"You're offline"* with Retry; nothing
  is queued, so no command can run later by surprise.

## Motion system

See `BrainboxAgent/DesignSystem/Motion.swift`. One signature spring
(response 0.42, damping 0.86), three durations, one entrance pattern (rise +
de-blur, 35 ms stagger capped at 360 ms), faster ease-in exits, ambient layer
via the agent orb and status pulses, full Reduce Motion fallbacks. The orb
(`AgentOrb`, `Canvas` + `TimelineView`) encodes agent state: breathing (ready),
comet arc (thinking), satellites (streaming), rotating dashed ring (tool),
still/desaturated (offline/error). Haptics accompany sends, tool success/
failure and presses.

## Folder map

```
BrainboxAgent/
  App/            entry point, AppModel, ChatStore, settings, security, root/tab bar/lock
  DesignSystem/   Theme, Motion, AgentOrb, Components, CodeAndMarkdown
  Features/       Home · Agent · VPS · Files · Settings
  Resources/      Assets (icon, accent)
BrainboxAgentTests/    hosted unit tests for the app layer
BrainboxAgentUITests/  critical-path UI tests (mock providers, -uitesting)
Packages/BrainboxCore/ core package + tests
.github/workflows/     ci.yml (always), signed-ipa.yml (manual)
scripts/               IPA packaging, simulator picker, CI log annotations
docs/                  this documentation
```
