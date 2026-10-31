# Brainbox Agent

Your Hermes agent on iPhone. Brainbox 2 connects **straight to your server over
SSH, the same way Hermes Desktop does**: it starts (or reuses) `hermes serve`
on the server and speaks Hermes' own gateway protocol through the SSH
connection — your persona, every slash command, approvals, sub-agents, the lot.
No proxy, no extra port, nothing new installed on the server. Native SwiftUI,
built and packaged on GitHub so no Mac is required.

**Connect:** [docs/CONNECT.md](docs/CONNECT.md) — enter your VPS address, run
one command on the server to authorize the phone's key, tap Connect.

## What's inside

- **Chat** — streaming Markdown, tool cards with output and diffs, reasoning,
  approvals / questions / sudo / secret prompts inline, todo plan, `/btw`,
  `/bg`, every Hermes slash command with live completion, model picker,
  photos and files, push-to-talk and hands-free voice through Hermes' own
  speech endpoints. Drops reconnect and replay what was missed.
- **Sessions** — every Hermes session from every surface; Telegram and cron
  chats are read-only.
- **Agents** — scheduled jobs (blueprints, custom, pause, run now, history)
  and live sub-agents (watch, steer, stop).
- **Hub** — a root terminal over SSH, files (browse, edit, upload, download),
  server health, logs, skills, toolsets, MCP servers, memory, star map,
  persona, curator, messaging platforms + gateway control, webhooks, pairing,
  models, profiles, usage, plugins, updates & doctor, code review, backups,
  import from other agents.
- **Pets** — Hermes petdex companions animate with what the agent is doing.
- **System** — local notifications (approve/deny/reply from the banner),
  background refresh, Live Activity + Dynamic Island, home-screen widget,
  Siri / Shortcuts ("Ask Brainbox", "Talk to Hermes"), "Open in Brainbox".
- **Security** — Ed25519 key generated on the phone and kept in the Keychain,
  pinned server host key (fails closed if it changes), optional Face ID for
  the key and the terminal, confirmations for gateway/config/update actions.

## How it works

```
iPhone ──SSH──▶ VPS
  HermesKit      ├─ sh: locate hermes, start/reuse `hermes serve --isolated
  (SwiftNIO SSH) │       --host 127.0.0.1 --port 0` (one-shot token file)
                 └─ direct-tcpip ─▶ 127.0.0.1:<port>  HTTP /api/* + WS /api/ws
                                    (Hermes' JSON-RPC gateway, like Desktop)
```

`Packages/HermesKit` holds the engine and is tested end to end in CI against a
real `sshd` and a real `hermes serve` (the VPS's Hermes 0.21.2 and current
main) with a fake model, so no keys are needed. The older API-server proxy in
`gateway/` is kept for reference but the app no longer needs it.

## Quick start

| I want to… | Do this |
|---|---|
| Install it on my iPhone | Download the `BrainboxAgent-unsigned-ipa` artifact from the latest green **CI** run and follow [docs/BUILD_AND_SIDELOAD.md](docs/BUILD_AND_SIDELOAD.md) |
| Try it without a server | It starts on **Mock** — ask "check server status", "run a long deploy", "trigger an error"… |
| Connect my Hermes | Follow [docs/HERMES_API_DEPLOYMENT.md](docs/HERMES_API_DEPLOYMENT.md), then Settings → **Hermes** (URL + device token) → Test connection |
| Connect another agent | Run a Brainbox gateway, then Settings → Connection (URL + token) → Agent → **Remote Agent** |
| Develop | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) |

## Documentation

| Doc | |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | layers, provider abstraction, concurrency, motion system |
| [AGENT_PROTOCOL.md](docs/AGENT_PROTOCOL.md) | exact WebSocket protocol a backend must implement |
| [CONNECT.md](docs/CONNECT.md) | **connect to Hermes over SSH** (Brainbox 2) |
| [HERMES_API_DEPLOYMENT.md](docs/HERMES_API_DEPLOYMENT.md) | older API-server + proxy route (no longer needed) |
| [MOTION.md](docs/MOTION.md) | motion moments shipped / deferred, Motion Lab |
| [HERMES_INTEGRATION.md](docs/HERMES_INTEGRATION.md) | older WebSocket-gateway route (library adapter, probe) |
| [BUILD_AND_SIDELOAD.md](docs/BUILD_AND_SIDELOAD.md) | CI, IPA, Sideloadly / SideStore / AltStore / paid signing |
| [SECURITY.md](docs/SECURITY.md) | security review and gateway requirements |
| [DEVELOPMENT.md](docs/DEVELOPMENT.md) | workflow, mock mode, adding providers, tests |

## Repository layout

```
BrainboxAgent/            SwiftUI app (App, Design, Features, Intents, Resources)
BrainboxWidgets/          home-screen widget + Live Activity extension
Shared/                   types shared by the app and the widget extension
BrainboxAgentTests/       hosted unit tests
BrainboxAgentUITests/     UI tests + screenshots (demo data)
Packages/HermesKit/       SSH engine: NIO SSH, tunnelled HTTP/WebSocket, hermes serve lifecycle, gateway RPC, chat engine
Packages/BrainboxCore/    shared models and text utilities (Markdown, syntax highlighting)
scripts/e2e/              fake OpenAI-compatible model for end-to-end tests
gateway/                  Python gateway (protocol server, Hermes adapters, probe, deploy files)
project.yml               XcodeGen spec (the .xcodeproj is generated)
.github/workflows/        ci.yml · signed-ipa.yml
scripts/                  IPA packaging and CI helpers
docs/
```

Requirements: iOS 17+, iPhone or iPad. Built with Swift 5 language mode on the Xcode
that ships on GitHub's `macos-15` runner.
