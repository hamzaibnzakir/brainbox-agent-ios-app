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
`hermes serve --isolated --host 127.0.0.1 --port 0` (one-shot token via a private file, its own
ownership id so it never touches the phone's backend) → Hermes' JSON-RPC gateway through an SSH
tunnel. No port is opened on the server or the PC. After updating Hermes on the server, use
**Connection › Restart backend**.

## Using it

| | |
|---|---|
| **Workspace** | Chat on the left, Hermes' screen on the right. |
| **Chat** | Streaming replies, tool cards, approvals (once / session / always / deny), questions, sudo/secret prompts (masked), slash commands, `/bg`, `/btw`, file and image attachments, Stop. |
| **Screen** | Hermes' Bot Screen. **Take over** → your keyboard and mouse drive it (red frame); Ctrl+Alt+Del button; **Hand back** when done. **Hand back (force)** clears a hold left by another device or an earlier connection. **Actual size / Fit**, **Turn off**, and install guidance when the server lacks the packages. |
| **Terminal** | A real login shell on the server (xterm.js over an SSH PTY). |
| **Sessions** | Every Hermes chat; Telegram and cron chats open read-only. |
| **Notifications** | Windows notifications when a reply lands, when Hermes needs approval, and when it stops at a step only you can do on its screen (click → opens the Workspace). |

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
