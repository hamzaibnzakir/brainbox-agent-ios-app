# Brainbox Agent

Your personal AI agent control center for iPhone — chat with your agent,
watch it run tools, and manage the VPS it lives on: metrics, services,
terminal, logs and files. Native SwiftUI, built and packaged entirely on
GitHub so no Mac is required.

> **Hermes: gateway built, awaiting verification.** The app ships with a
> clearly-labelled **Mock** backend and a **Remote Agent** backend that speaks
> the [Brainbox Agent Protocol](docs/AGENT_PROTOCOL.md). The
> [Brainbox gateway](gateway/) bridges that protocol to Hermes; it refuses to
> call Hermes until a read-only probe has confirmed the API on your VPS — see
> [docs/HERMES_INTEGRATION.md](docs/HERMES_INTEGRATION.md).

## Features

- **Agent chat** — streaming markdown, syntax-highlighted code blocks with
  copy, inline tool cards (terminal, file, git, service, network…) with live
  output, stop / retry / regenerate, titles, searchable history, offline
  reading.
- **Home** — the animated agent core, status, current backend, live server
  health, quick actions, recent conversations and activity.
- **VPS** — CPU / memory / disk rings, network sparklines, services with
  start / stop / restart, processes, system info, cached offline snapshot.
- **Terminal** — multiple sessions, streaming output, history (↑/↓),
  interrupt, copy, clear.
- **Logs** — live stream, pause/resume, category & severity filters, search,
  copy, clear viewer (never touches server logs).
- **Files** — browse backend-approved roots, search, sort, create, rename,
  delete (Face ID), and a code editor with line numbers, highlighting
  (YAML/JSON/JSONC/Markdown/Python/Shell), find & replace, undo/redo,
  validation, diff-before-save and conflict detection.
- **Security** — Keychain-only secrets, Face ID for sensitive actions, app
  lock, privacy cover, local-only clipboard.
- **Motion** — one coherent spring-based motion system: staggered entrances,
  morphing controls, a living agent orb that shows what the agent is doing,
  haptics, full Reduce Motion support.

## Quick start

| I want to… | Do this |
|---|---|
| Install it on my iPhone | Download the `BrainboxAgent-unsigned-ipa` artifact from the latest green **CI** run and follow [docs/BUILD_AND_SIDELOAD.md](docs/BUILD_AND_SIDELOAD.md) |
| Try it without a server | It starts on **Mock** — ask "check server status", "run a long deploy", "trigger an error"… |
| Connect a real agent | Run a Brainbox gateway, then Settings → Connection (URL + token) → Agent → **Remote Agent** |
| Develop | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) |

## Documentation

| Doc | |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | layers, provider abstraction, concurrency, motion system |
| [AGENT_PROTOCOL.md](docs/AGENT_PROTOCOL.md) | exact WebSocket protocol a backend must implement |
| [HERMES_INTEGRATION.md](docs/HERMES_INTEGRATION.md) | what we need from Hermes and how the adapter will work |
| [BUILD_AND_SIDELOAD.md](docs/BUILD_AND_SIDELOAD.md) | CI, IPA, Sideloadly / SideStore / AltStore / paid signing |
| [SECURITY.md](docs/SECURITY.md) | security review and gateway requirements |
| [DEVELOPMENT.md](docs/DEVELOPMENT.md) | workflow, mock mode, adding providers, tests |

## Repository layout

```
BrainboxAgent/            SwiftUI app (App, DesignSystem, Features, Resources)
BrainboxAgentTests/       hosted unit tests
BrainboxAgentUITests/     UI tests (mock providers)
Packages/BrainboxCore/    models, protocols, transport, providers, core tests
gateway/                  Python gateway (protocol server, Hermes adapters, probe, deploy files)
project.yml               XcodeGen spec (the .xcodeproj is generated)
.github/workflows/        ci.yml · signed-ipa.yml
scripts/                  IPA packaging and CI helpers
docs/
```

Requirements: iOS 17+, iPhone. Built with Swift 5 language mode on the Xcode
that ships on GitHub's `macos-15` runner.
