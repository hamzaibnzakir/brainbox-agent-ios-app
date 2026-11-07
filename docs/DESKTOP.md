# Brainbox for Windows

The desktop companion to the iPhone app: chat with Hermes on your server, and work **side by side
with Hermes' own computer** — watch its browser live, take over with your real keyboard and mouse
for a login, CAPTCHA, 2FA or payment step, then hand back. The phone, this app and Hermes Desktop
all see the same screen under the same control lock (see [BOT_SCREEN.md](BOT_SCREEN.md)).

Code: `desktop/` (Electron + TypeScript + React). Built by CI on `windows-latest`.

## Install

1. Download from the latest `brainbox-2-build-N` pre-release (or the `Brainbox-Windows` CI artifact):
   - **`Brainbox-Setup-2.0.0.exe`** — installs for your user, with a Start-menu and desktop shortcut.
   - **`Brainbox-Portable-2.0.0.exe`** — runs without installing.
2. The app isn't code-signed yet, so Windows SmartScreen says **"Windows protected your PC"**.
   Click **More info → Run anyway**. (Signing needs a code-signing certificate; it removes this step.)

## Pair this PC (once)

1. Enter the VPS **host**, **port** `22`, **user** `root`.
2. Copy the command under **Let this PC in** and run it once on the server. It appends this PC's
   **public** key to `~/.ssh/authorized_keys`. The private key was generated on the PC and is stored
   encrypted by Windows (DPAPI, via Electron `safeStorage`) — never in plain text.
3. **Connect.** The first connection pins the server's SSH host key; if it ever changes, Brainbox
   refuses to connect until you choose **Reset trusted server key**.

Under the hood it is the phone's connection, ported: SSH (key auth only) → start or reuse
`hermes serve --isolated --host 127.0.0.1 --port 0` (one-shot token via a private file) → Hermes'
JSON-RPC gateway through an SSH tunnel. No port is opened on the server or the PC. After updating
Hermes on the server, use **Connection › Restart backend** (the phone reconnects to the new one).

## One chat, every device

The phone and every PC use **one shared backend** on the server
(`~/.hermes/desktop-ssh/9bfaf1f3f5d1b43167520d9fb4c60c03/`, token in a 0600 file next to the lock;
whoever connects first starts it, the rest adopt it). Hermes' gateway owns the conversation, so a
chat open on both devices is the same live chat: start a message on the phone, hand the phone to
someone, and the reply keeps streaming on the PC — and the other way round. Each device also shows
the prompt the other one sent (fetched from `session.history`), and catches up when its window or
app comes back to the front. Backends that older builds started per device are stopped on the
first connect.

## Using it

Dark-first design with the phone's palette; a navigation rail on the left, a status bar at the bottom.

| | |
|---|---|
| **Chats** | Every Hermes chat grouped by day, with search; Telegram / cron / other-app chats sit under *Other apps* and open read-only. Right-click (or ⋯) to rename or delete. A pulsing dot marks chats Hermes is working on — from any device. |
| **Conversation** | Streaming replies with Markdown, tables and highlighted code (Copy on every block), collapsible reasoning and tool rows, approvals (once / this chat / always / deny), questions, masked sudo/secret prompts, the plan (todos), *Jump to latest*. |
| **Composer** | Enter sends, Shift+Enter new line, ↑ recalls earlier prompts, `/` opens Hermes' command list (Tab completes), model picker, attach / drop / paste files and images, Stop (or Esc). |
| **Hermes' screen** | Ctrl+J docks it beside the chat (drag the divider to resize) or open it full size from the rail. **Take over** → your keyboard, mouse and touchpad drive it (red frame); Ctrl+Alt+Del; **Hand back**. Same viewer in both places, so switching never drops control. |
| **Terminal** | A real login shell on the server (xterm.js over an SSH PTY). |
| **Scheduled jobs** | Hermes' cron: create (with presets and delivery target), edit, pause / resume, run now, delete. |
| **Skills** | All skills by category with search; switch each on or off; read its SKILL.md; "Use in a chat". |
| **Memory** | Edit Hermes' notes (`MEMORY.md`) and what it knows about you (`USER.md`) like documents (Ctrl+S); memory providers. |
| **Files** | Browse the server, open and edit text files, copy paths, "Ask Hermes" about a file. |
| **Server** | Live CPU / memory / disk, Hermes version and RAM, model and context size, component health. |
| **Settings** | Connection, this PC's key, notifications, theme (dark / light / system), restart backend, reset server key. |

Keyboard: **Ctrl+K** search everything (chats, pages, actions) · **Ctrl+N** new chat · **Ctrl+J** screen beside
the chat · **Ctrl+B** hide/show the chats list · **Ctrl+1…8** pages · **Ctrl+,** settings · **Ctrl+Shift+F** search chats.

While Hermes drives its browser, the chat shows **"Hermes is using its browser — watch live"**;
when a browser turn ends by asking for you, it shows **"Hermes needs you on its screen"**.

Closing the screen (switching chats, quitting) closes the stream cleanly, which hands control back.
A dropped connection keeps your control on purpose (you might be mid-login) until you reconnect and
hand back.

## Security notes

- The window runs with context isolation, no Node, a strict CSP and Electron's sandbox; it reaches
  the main process only through the small `bb` bridge in `desktop/src/main/preload.ts`.
- Links in replies open in your normal browser, never inside the app.
- Secrets (SSH key, backend session tokens) are encrypted with the OS keystore. On Linux without a
  keyring they fall back to a 0600 file, and the Connection screen says so.
- Same server-side caveats as the phone: Hermes runs as root on this VPS, so its screen does too,
  and the control lock is a tool-level fence (see BOT_SCREEN.md).

## Development

```bash
cd desktop
npm ci
npm run typecheck
npm test                      # unit tests; live tests run when HERMES_E2E_SSH_* are set
npm start                     # build and run
npm run dist:win              # installer + portable exe (on Windows)
```

`test/live.test.ts` runs the engine against a real sshd + `hermes serve` (+ Bot Screen with
`HERMES_E2E_SCREEN=1`), the same environment as the phone's live tests. `test/ui-smoke.mjs` drives
the real Electron app (connect → chat → approval → Workspace screen take over / hand back →
terminal) and saves screenshots; `BRAINBOX_APP_EXE` points it at a packaged build. CI runs both on
the Linux end-to-end job for Hermes 284d220 and main, and builds the Windows installer on
`windows-latest`.

The engine in `desktop/src/main/hermes/` is a TypeScript port of `Packages/HermesKit` and
`desktop/src/shared/transcript.ts` of `Transcript.swift`; keep them in step when the gateway
protocol changes.
