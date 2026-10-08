# Development guide

## Without a Mac (the normal workflow here)

1. Edit code anywhere (GitHub web editor, VS Code on Windows, Codespaces…).
2. Run the core tests locally on Linux/WSL if you have Swift installed:
   ```bash
   cd Packages/BrainboxCore && swift test
   ```
   (Install Swift for Linux/WSL from swift.org. The core has no Apple-only
   dependencies.)
3. Push a branch (`feature/<name>`) → the **CI** workflow compiles the app,
   runs unit + UI tests on a simulator and produces an unsigned IPA.
4. Failures show up as **annotations** on the run (compiler errors and failing
   tests are extracted by `scripts/ci/annotate-log.sh`), so you rarely need the
   raw log.
5. Merge to `main` when green.

## With a Mac

```bash
brew install xcodegen
xcodegen generate          # re-run whenever files are added/removed
open BrainboxAgent.xcodeproj
```

Run the `BrainboxAgent` scheme. ⌘U runs unit + UI tests.

## Development mode (no server needed)

The app starts on the **Mock** provider. Everything works offline:

| Surface | Mock behaviour |
|---|---|
| Agent chat | Keyword-driven scenarios: `status`/`server`/`health`, `config`/`file`, `python`/`code`, `deploy`/`long`, `error`, `disconnect`. Anything else gets a help reply |
| Tools | Terminal / system / git / service / file tool cards with streamed output |
| VPS | Drifting CPU/RAM/network metrics, controllable services (start/stop/restart) |
| Terminal | Pretend shell: `help`, `ls`, `cd`, `pwd`, `uname -a`, `df -h`, `free -h`, `systemctl status x`, `ping`, `sleep n` (cancellable). Destructive commands are refused |
| Files | In-memory tree with allow-listed roots `/home/brainbox`, `/etc/brainbox` and read-only `/var/log/brainbox`; conflict detection on save |
| Logs | Live stream across all categories |

Settings → Developer has one-tap scenario shortcuts and a provider switcher
(Mock / Remote Agent / Future Hermes — disabled). Debug-only actions are
compiled out of Release builds with `#if DEBUG`.

UI tests launch the app with `-uitesting` (DEBUG builds only): fast mocks,
biometrics bypassed, throw-away storage.

## Adding a provider (e.g. OpenAI, Anthropic, local model)

1. Add a case to `ProviderKind`.
2. Implement `AgentProvider` (and any of `VPSProvider`, `TerminalProvider`,
   `FileSystemProvider`, `LogStreamProvider` it supports) in
   `Packages/BrainboxCore/Sources/BrainboxCore/Providers/<Name>/`.
3. Emit only `AgentEvent`s; advertise accurate `capabilities`.
4. Build its `ProviderSuite` in `AppModel.rebuildSuite()`.
5. Add tests next to `MockProviderTests`.

Usually you won't need step 2 for the app: put the integration in the gateway
and keep using `RemoteAgentProvider`.

## Conventions

* Commits: `feat:`, `fix:`, `test:`, `docs:`, `ci:`, `chore:`.
* Branches: `main` (always green), `feature/*` for work.
* Never commit secrets — `.gitignore` blocks `.p12`, `.mobileprovision`,
  `.env`, keys. Tokens live in the Keychain at runtime only.
* Motion: use `Motion.*` tokens and `bbEntrance` / `.bbRise` — don't invent
  new curves per screen.
* Colours/fonts: use `BB.Palette` / `BB.Font` tokens only.

## Test inventory

| Suite | Where it runs | Covers |
|---|---|---|
| `WireProtocolTests` | Linux + macOS | envelope round-trip, every event ↔ frame, version check, error codes |
| `GatewayConnectionTests` | Linux + macOS | auth ok/failed/missing token, streaming, RPC, subscriptions, drop → fail in-flight → reconnect with `resumeSession`, cancel |
| `MockAgentProviderTests` / `MockSystemProviderTests` | Linux + macOS | scenarios, cancellation, connection-loss simulation, Hermes pending, file CRUD/permissions/traversal/conflicts, terminal, services, logs |
| `ModelTests`, `ChatReducerTests` | Linux + macOS | paths, history, log filters, metrics health, titles, error mapping, reducer, inline segments |
| `MarkdownParserTests`, `SyntaxHighlighterTests`, `TextToolTests` | Linux + macOS | markdown (incl. streaming fences), highlighter round-trip, diff, validators, search/replace |
| `SecurityTests`, `PersistenceTests` | Linux + macOS | biometric policy, URL/token validation, backoff, timeouts, credential store, conversation store, caches |
| `ChatStoreTests`, `SettingsAndSecurityTests`, `DesignSystemTests` | iOS simulator (hosted) | chat send/stop/retry/offline, settings persistence, Keychain round-trip, provider switching, motion budget |
| `CriticalPathUITests` | iOS simulator | chat, suggestions, all tabs, terminal command, opening a config file |
