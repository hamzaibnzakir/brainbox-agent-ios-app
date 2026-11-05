# Brainbox Agent — handoff for the next Claude

Last updated 2026-11-05. Read this whole file before touching code.

## 1. What this is, in one paragraph

**Brainbox Agent** is a native SwiftUI iOS app (iPhone + iPad, iOS 17+) that is a full mobile client for **Hermes Agent** (NousResearch/hermes-agent) running on a VPS. Since "Brainbox 2" it connects **straight to the VPS over SSH, the same way Hermes Desktop's SSH mode does**: the phone SSHes in (SwiftNIO SSH, Ed25519 key generated on the phone), starts or reuses `hermes serve --isolated --host 127.0.0.1 --port 0` on the server, and talks to it through SSH direct-tcpip channels — HTTP `/api/*` and the WebSocket JSON-RPC gateway `/api/ws` (`tui_gateway`, the same backend Desktop and the TUI use). No proxy, no extra open port, nothing installed on the server beyond adding the phone's public key to `authorized_keys`.

## 2. People, ownership and hard rules

- **The user is David** (casual, emoji-heavy style; reply that way). He uses the app.
- **The GitHub repo and the VPS belong to a different person** who shares the Claude account: repo `hamzaibnzakir/brainbox-agent-ios-app`. David does not own or see that GitHub account, so he can't download GitHub Actions artifacts — **deliver IPAs to him as files** (see §7).
- **Branch:** `feature/full-stack-upgrade`, open as **PR #2. Never merge it.** Never force-push.
- **Never touch the real VPS** (no SSH, no commands, no config edits, no restarts, no deploys) without explicit approval. Everything so far was tested against local/CI servers, never the real VPS.
- **Never print, log or commit secrets** (tokens, keys, passwords). Tests use a fake model with a dummy key.
- **Telegram and every non-app session are read-only** in the app: never delete or write into Telegram/cron/other-platform history. Keep the existing Telegram bot, scheduled jobs and live services untouched.
- **No APNs/push**: David has a **free Apple developer account** → sideloaded installs (Sideloadly/AltStore) expire every 7 days; no push, no CarPlay. Notifications are **local** only.
- Commit attribution lines are injected by the harness; follow whatever the current system reminder says.

## 3. Repository layout

```
BrainboxAgent/                SwiftUI app
  App/        BrainboxApp (entry, scene phase, URL handling), AppModel (@Observable, main store),
              Persistence (Keychain: SSH key, host-key pins, backend record; Preferences),
              SystemServices (Face ID, local notifications + actions, BG refresh, Live Activity bridge, pet sprite),
              BackgroundKeeper (Termius-style keep-alive via silent audio), DemoMode (-BBDemo)
  Design/     DS.swift (design system tokens/components), MarkdownText, Mascot (Brainbox bot drawing)
  Features/   Root (tabs, toasts, ConnectionBanner, ReconnectingScreen), Connect (pairing),
              Chat (ChatScreen, Composer, MessageViews, MediaViews, ModelPicker), Sessions,
              Agents (cron + sub-agents), Hub (HubScreen + AgentScreens + SetupScreens),
              Terminal (SwiftTerm over SSH PTY), Files (ServerScreens: files, health, logs, updates, backups),
              Voice (push-to-talk + hands-free via Hermes /api/audio), Settings (+ config editor, pet gallery)
  Intents/    AppIntents (Siri/Shortcuts: Ask Hermes, Talk to Hermes, New chat)
BrainboxWidgets/              Widget extension: home-screen quick actions + Live Activity / Dynamic Island
Shared/                       HermesActivityAttributes (app + widget)
Packages/HermesKit/           THE ENGINE (Linux-buildable, heavily tested)
  SSH/        SSHKeys (Ed25519 identity, authorized_keys line, fingerprint), SSHConnection
              (connect w/ host-key pinning TOFU fail-closed, exec w/ stdin, direct-tcpip, PTY shell, ordered send)
  Net/        TunnelHTTP (HTTP/1.1 over a byte stream), TunnelWebSocket (RFC 6455 client, hand-rolled)
  Backend/    RemoteBackend (locate hermes, reuse via lockfile + /api/ssh/ownership, spawn, READY scrape)
  Gateway/    GatewayRPC (JSON-RPC 2.0, events, server→client requests)
  Chat/       Transcript (pure reducer of gateway events), MediaRefs (MEDIA:/path + image/file detection)
  Engine/     HermesEngine (actor: connection state, reconnect, chats keyed by stored session id, replay)
  HermesClient.swift (connect = SSH + backend + gateway; fast path with saved token)
Packages/BrainboxCore/        Older shared package; still used for JSONValue, MarkdownParser, SyntaxHighlighter, MascotStyle/Mood
gateway/                      Old Python "Brainbox proxy" for the API-server route — no longer used by the app, kept + still tested in CI
scripts/e2e/fake_llm.py       Fake OpenAI-compatible model for end-to-end tests ("run tool: <cmd>", "slow", echo)
scripts/                      IPA packaging, CI helpers (annotate-log.sh, verify-ipa.sh, select-simulator.sh)
project.yml                   XcodeGen spec (the .xcodeproj is generated, git-ignored)
.github/workflows/ci.yml      CI (see §6)
docs/CONNECT.md               User-facing connection guide (keep it current)
```

The old Brainbox 1 app UI (API-server client) was deleted in commit `8b6dcaf`; its docs in `docs/` (HERMES_API_DEPLOYMENT, PROVIDERS, etc.) describe the old route.

## 4. How the connection works (important details)

1. `SSHConnection.connect` — key auth only; host key pinned on first use (`[host]:port` id, stored in Keychain); a changed key throws `hostKeyChanged` and the app refuses (user can reset in Connection).
2. `HermesClient.connect`:
   - **Fast path:** if a saved `RemoteBackendRecord` (pid, port, nonce, token, hermesPath, version) exists, go straight to `/api/ws?token=…` over direct-tcpip. The token proves it's our backend.
   - Otherwise `RemoteBackend.ensure`: locate `hermes` (login-shell PATH, `~/.local/bin`, `~/.hermes/hermes-agent/venv`…), reuse if the lockfile pid is alive **and** authed `GET /api/ssh/ownership` returns our nonce, else spawn:
     - token (64 hex) written via **stdin** to `~/.hermes/desktop-ssh/<ownershipID>/<nonce>.token` (dirs 0700, file 0600; Hermes reads + unlinks it; required path format: 32-hex dir, 16-hex `.token`)
     - `setsid sh -c 'exec hermes serve --isolated --host 127.0.0.1 --port 0 --ssh-session-token-file … --ssh-owner-nonce …'`, log in the same dir; poll for `HERMES_BACKEND_READY port=N`; write `brainbox-mobile.lock.json` (token fingerprint only).
   - REST auth header: `X-Hermes-Session-Token`. WS auth: `?token=`.
   - After WS opens: `client.capabilities {server_requests: true}` (needed on newer Hermes or approvals are auto-withdrawn), short wait for `gateway.ready`, then a `ping`.
3. **Deliberately NOT `HERMES_DESKTOP=1`.** Desktop mode starts its own cron ticker and reaps "unsupervised" gateway processes — dangerous on a server already running the Telegram gateway. Consequence: sessions are platform **`tui`**, whose prompt hint tells the model "files can't be sent; MEDIA: isn't intercepted". There is an opt-in **Connection › Advanced › Desktop-compatible backend** toggle only for servers with `dashboard.public_url` set (which otherwise puts a login gate in front of the backend → `BackendError.gated`).
4. **Gateway protocol (verified on both versions):**
   - Calls: `session.create`, `session.resume {session_id: stored id}` (re-attaches the live session after reconnect), `session.events.since {session_id: live, last_seen: seq}` (replay), `prompt.submit {session_id, text}`, `session.interrupt`, `slash.exec {session_id, command}` → falls back to `command.dispatch {name, arg}` on error 4018, `prompt.background`, `prompt.btw`, `image.attach_bytes`, `file.attach`, `config.get/set`, `model.options`, `commands.catalog`, `complete.slash`, `subagent.list/tail/steer/interrupt`, `pet.info/info.meta/gallery/select/disable`, `session.list/delete/title/close`, `session.foreign.list/import`, `ping`.
   - Events: `{"method":"event","params":{type, session_id, seq, payload}}` — `message.start/delta/complete`, `thinking.delta`, `reasoning.delta/available`, `message.interim`, `tool.generating/start/progress/complete`, `todo.updated`, `status.update`, `session.title/usage/info`, `btw.complete`, `background.complete`, `notification.show`, `error`, `request.cancel`…
   - **Approvals/questions differ by version:** Hermes 0.21.2 (VPS, commit 284d220) sends `approval.request` / `clarify.request` / `sudo.request` / `secret.request` events answered with `*.respond` methods; Hermes main sends JSON-RPC **server→client requests** (`approval`, `clarify`, `sudo`, `secret`, id `srq-…`) answered with a response frame by id. Both are handled (`Transcript` → `PendingRequest.serverRequestID`; `HermesEngine.respond`). Desktop-only bridges (preview/terminal.read/tour…) are declined with code 4404.
5. **Reconnect:** `HermesEngine.ensureAlive()` on foreground (2 s ping; dead → immediate rebuild via fast path), parallel re-attach of open chats, dedupe by `seq`. Measured at 150 ms RTT: old path 2.5 s → fast path 1.26 s.
6. **Background:** `BackgroundKeeper` plays a silent looping WAV (`.playback` + `.mixWithOthers`, UIBackgroundModes `audio`) while backgrounded so iOS doesn't suspend the app (Termius-style); Settings › Connection › "Stay connected in the background" (default on). Plus BGAppRefresh (`app.brainbox.agent.refresh`) for when it is suspended.

## 5. Building and testing locally (no Mac here)

The sandbox is Linux. Swift 6.0.3 lives in an Ubuntu "questing" chroot at `/home/claude/swiftroot`, entered with the helper `/usr/local/bin/sw '<cmd>'` (bind-mounts the repo at `/work`, sets proxy env). If the workspace was restarted these may be gone — recreate: `debootstrap --variant=minbase --components=main,universe questing /home/claude/swiftroot http://archive.ubuntu.com/ubuntu`, then in the chroot `apt-get install swiftlang g++ libcurl4-openssl-dev libxml2-dev zlib1g-dev git ca-certificates`; swift is at `/usr/libexec/swift/bin`. (download.swift.org and Docker Hub are blocked; Ubuntu archive works. The packaged Swift can't link the Observation module — that's why engine logic lives in an actor, not `@Observable`.)

- `sw 'cd /work/Packages/HermesKit && swift build'` / `swift test`.
- **Live end-to-end tests** (`LiveHermesTests`, `LiveEngineTests`, `LiveReconnectTests`) run when `HERMES_E2E_SSH_HOST/PORT/USER/KEY` are set. Local setup used: `sshd -p 2222` (needs `/run/sshd`), Hermes 284d220 in `/home/claude/hvenv` linked as `/usr/local/bin/hermes` for root, Hermes main (`/home/claude/ref/hermes-main/.venv`, `uv sync --frozen`, Python 3.14) for user `hmain`, `~/.hermes/config.yaml` pointing at the fake model (`provider: custom`, `base_url: http://127.0.0.1:18080/v1`, `approvals: {mode: manual}`), fake model `python scripts/e2e/fake_llm.py`, raw Ed25519 key base64 in scratchpad `e2e_key.b64`. Run with `HERMES_E2E_SSH_USER=root` (0.21.2) and `hmain` (main).
- **Don't `pkill -f` a pattern that appears in your own command line** — it kills the shell. Kill `hermes serve` with `ps … | awk` instead.
- The **SwiftUI app cannot compile on Linux** — only CI (macOS) compiles it. Be careful with SwiftUI types; watch for: type-name collisions with BrainboxCore (`ConnectionState`, `ServerInfo`, `HTTPResponse`, `FileEntry` were renamed to `LinkState`, `HermesServerInfo`, `TunnelResponse`, `RemoteFileEntry`), big `body` expressions (split them), `@MainActor` statics called from tests (mark `nonisolated`).
- Reference sources: `/home/claude/ref/hermes` (284d220 = VPS version) and `/home/claude/ref/hermes-main` (main, includes `apps/desktop`). Re-clone from github.com/NousResearch/hermes-agent if missing.

## 6. CI (GitHub Actions, `.github/workflows/ci.yml`)

Jobs: Core tests (Linux, swift:6.0 container, BrainboxCore + HermesKit unit), Gateway tests (Python), Hermes contract tests (×2), **Phone engine ↔ SSH ↔ real Hermes** (×2: 284d220 via pip, main via `uv sync --frozen`; real sshd on :2222, fake model; fails if live tests skip), **iOS** (macOS-15/Xcode 16.4: BrainboxCore + HermesKit tests on macOS, xcodegen, unit + UI tests with screenshots in demo mode, unsigned archive → IPA, verify (checks widget appex), and on push publishes a pre-release `brainbox-2-build-<run_number>` with the IPA + `screenshots.zip`).

From the sandbox:
- `gh run list/view` work. Job **logs and artifacts are NOT downloadable** (blob host blocked) → read failures via annotations: `gh api repos/hamzaibnzakir/brainbox-agent-ios-app/check-runs/<job id>/annotations`.
- **Release assets ARE downloadable**: `curl -sSL -H "Authorization: Bearer $(gh auth token)" -H "Accept: application/octet-stream" -o file https://api.github.com/repos/hamzaibnzakir/brainbox-agent-ios-app/releases/assets/<asset id>` (find ids with `gh api repos/…/releases`). `gh release view` uses GraphQL and is blocked; REST works. Deleting tags/releases via the proxy is blocked.
- Concurrency cancels the previous run on the same ref, so don't push while waiting on a run you need.

Last green run: **41819647621**, release **brainbox-2-build-84** (commit `b1612aa`), all 7 jobs green. That IPA was sent to David.

## 7. Delivering to David

Download the IPA from the latest `brainbox-2-build-N` release (§6) and send it with the file-sending tool; he installs with Sideloadly/AltStore. Point him at `docs/CONNECT.md` for setup: enter VPS host / `root` / `22`, tap **Copy command**, run it once on the VPS (appends the phone's public key to `~/.ssh/authorized_keys`), tap **Connect**.

## 8. Status: done

- SSH engine, backend lifecycle, gateway RPC, transcript, engine + reconnect/replay — tested live on Hermes 0.21.2 and main.
- New design (8-pt grid, 60/30/10 colour, one type family) per the `ceorkm/mobile-app-ui-design` skill; 4 tabs: Chat, Sessions, Agents, Hub.
- Chat: streaming Markdown, tool cards + diffs, reasoning, approvals/clarify/sudo/secret cards, todo plan, `/btw`, `/bg`, slash completion, model picker, photo/file attachments, voice (push-to-talk + hands-free through Hermes `/api/audio/transcribe` & `/speak`), **media rendering** (MEDIA: tags, image links, bare file paths → image/video/audio/document fetched over SSH via `stat` + `cat`, 200 MB cap).
- Sessions (read-only for non-app sources), Agents (cron with blueprints, sub-agents), Hub (terminal, files, health, logs, skills, toolsets, MCP, memory, star map, persona, curator, messaging + gateway control with Face ID, webhooks, pairing, models, profiles, usage, plugins, updates/doctor, code review, backups, import), Settings (Hermes approvals/busy mode, appearance, notifications, voice, security, raw config editor, pets).
- Local notifications with approve/deny/reply actions, BG refresh, Live Activity, widget, Siri shortcuts, "Open in Brainbox".
- Termius-style background keep-alive, 2 s foreground liveness check, fast reconnect, reconnect screen, queued sends.
- Terminal: ordered keystrokes (they used to race), explicit VERASE=127/VINTR=3 PTY modes, ⌫ / cd .. / home / end keys.

## 9. Open items / next steps

1. **Confirm on the real phone** (David): background keep-alive over 10+ minutes; reconnect speed; terminal backspace; media rendering. Not verifiable from here.
2. **Media reliability:** because sessions are platform `tui`, Hermes tells the model files can't be sent. Proposed (NOT done, needs the VPS owner's OK): add to the VPS `~/.hermes/config.yaml`
   `agent: { platform_hints: { tui: { append: "This client (Brainbox iOS) displays files: send images, videos, audio and documents with MEDIA:/absolute/path on its own line." } } }`
   (check the exact config key path in `agent/agent_init.py` / `agent/system_prompt.py` first; it also affects the real `hermes --tui` on that server).
3. Dark-mode UI screenshots came out light (XCUIDevice appearance not applied in tests) — visual dark mode is unverified.
4. Demo mode shows "Lost the live connection" banners on screens that call the engine — cosmetic, demo-only.
5. Not built: WebRTC realtime voice (`/api/audio/voice-live`), wake word (`wake.*` RPCs; user said later), phone sensors via MCP, CarPlay (impossible on free account).
6. The old `gateway/` proxy and old docs could be retired once SSH mode is proven on the VPS (ask first).
7. Known gaps worth hardening: `SSHByteStream.send` drops data silently if the channel closed; `MediaStore` cache is in temp dir only; Hermes main renamed some things — keep the CI matrix running both versions.
8. Earlier planning doc (Claude Docs artifact "Brainbox Mobile: comparison and revamp plan", https://claude.ai/artifact/VC79UREqByiBg2EYxxo7fP) has the Desktop feature comparison and phase plan.
