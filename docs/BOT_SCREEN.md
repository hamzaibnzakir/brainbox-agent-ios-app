# Hermes' screen (Bot Screen) in Brainbox

A permanent, shared computer for the agent — the Manus-style "watch it work, take over for the
CAPTCHA, hand back" flow — for every task, not one site.

Brainbox does not build its own remote desktop. It uses **Hermes' Bot Screen**, the feature Hermes
Desktop's Screen pane uses, so the phone and the PC see **the same screen under the same control
lock**:

- Each Hermes profile ("bot") gets its own Linux desktop on the server (TigerVNC `Xvnc` + Xfce),
  with the bot's **headed browser** on it and a persistent browser profile (logins and cookies
  survive across sessions).
- Anyone connected can **watch**. One person at a time can **take over**; while they hold control,
  Hermes refuses the bot's browser and computer-use tools (screenshots included, so the bot can't
  see a password being typed). **Hand back** and the bot continues with what you signed in to.
- The most recent **Take over** wins: take over on the phone, hand back from Hermes Desktop, or the
  other way round.

Hermes' own write-up: `website/docs/user-guide/features/bot-screen.md` in hermes-agent.

## How the phone connects (nothing new is exposed)

```
iPhone ──SSH (port 22)──▶ server
          │ direct-tcpip to 127.0.0.1:<backend port>  (the same tunnel chat already uses)
          ├─ /api/ws            JSON-RPC: display.status/start/stop/observe/lease.acquire/lease.release
          └─ /api/display/ws?display_ticket=…   raw RFB (VNC) as binary WebSocket frames
                                   │
                         hermes serve ──Unix socket (0600)──▶ Xvnc (the bot's screen)
```

1. `display.observe` returns a **single-use, 30-second ticket** and a viewer id bound to this
   gateway connection.
2. The phone opens `/api/display/ws` with that ticket through SSH. Hermes splices it to the screen's
   private Unix socket. There is no VNC port and no VNC password; the ticket and SSH are the gate.
3. The page that draws the screen is **noVNC 1.7.0** (the version Hermes Desktop bundles) in a
   `WKWebView`. The web view never touches the network: Swift owns the socket and passes bytes to
   the page as base64 (`BrainboxAgent/Features/Screen/ScreenSession.swift`,
   `scripts/novnc/viewer-entry.js`). Rebuild the page with `scripts/novnc/build.sh`.
4. `display.lease.acquire` / `release` take over and hand back. Hermes drops keyboard and pointer
   input from any viewer that doesn't hold the lease **at the byte level**, so "watching" really
   can't type.

Closing the screen in the app sends a clean WebSocket close, which hands control back. A **dropped**
link (no signal, phone locked mid-takeover) keeps control with you on purpose — Hermes assumes you
might be mid-login. Reopen the screen and tap **Hand back**, or use **Hand back (force)** from the
menu if the hold came from an earlier connection or another device.

## Using it

- **Hub › Hermes' screen**, the chat menu (**Hermes' screen**), or `brainbox://screen`.
- While Hermes drives its browser, the chat shows **"Hermes is using its browser — watch live"**.
- When a turn that used the browser ends by asking for you (login, CAPTCHA, 2FA, payment…), the chat
  shows **"Hermes needs you on its screen"** and, if the app is in the background, a time-sensitive
  notification opens straight onto the screen.
- **Take over** → tap to click, two fingers to scroll, long-press for right-click; type in the bar
  at the bottom (the eye button hides what you type), arrow/tab/esc/⌫/↵ keys, **paste** types your
  clipboard. Then **Hand back** and tell Hermes to continue.
- Typed text is sent as X keysyms, so characters arrive correctly whatever the screen's keymap.

Brainbox never tries to bypass a CAPTCHA or verification step; it puts you in front of it.

## What the server needs (VPS owner — not done by Brainbox)

The VPS currently runs Hermes **284d220 (0.21.2)**, which has **no Bot Screen**; the app says
"This Hermes doesn't have Bot Screen yet" there. CI proves the feature against Hermes main
**1c0cd66**, which has it.

Checklist, in order. Each step is the owner's call; Brainbox never runs these by itself.

1. **Back up** `~/.hermes` (Hub › Backups, or your own copy).
2. **Update Hermes** to a version with Bot Screen (at least the CI pin `1c0cd66`), with Hermes' own
   updater (`hermes update`). Plan for the Telegram gateway (`hermes-gateway.service`) restarting
   as part of the update, and check it afterwards (`hermes gateway status`).
3. **Install the screen packages** (~930 MB of disk):
   `hermes computer-use screen install -y` — or on Debian/Ubuntu:
   `apt-get install -y tigervnc-standalone-server xfce4-panel xfwm4 xfdesktop4 xfce4-settings xfce4-terminal dbus-x11 x11-xserver-utils x11-utils xauth fonts-dejavu-core`
   (add `chromium` if `hermes computer-use screen status` reports no headed browser).
4. **Config** (`~/.hermes/config.yaml`):
   ```yaml
   browser:
     headed: true          # the bot's browsing shows on the screen
   bot_desktop:
     auto_start: true      # bring the screen up on the bot's first browser use
     idle_stop_minutes: 30 # stops when nobody uses it (comes back on next use)
   ```
5. **Restart Brainbox's backend** so it runs the new Hermes: app › Connection › **Restart backend**
   (the phone otherwise reuses the `hermes serve` it started before the update).
6. Open **Hub › Hermes' screen** → **Start screen**.
7. Retire the temporary setup (Chrome on a shared VNC desktop) once the Bot Screen works. Its logins
   don't carry over: the Bot Screen's browser has its own profile, so sign in to Meta Ads Manager
   once during a takeover.

Rollback: `hermes computer-use screen stop --force`, set `bot_desktop.auto_start: false`, and roll
Hermes back with your backup / previous version.

## Resource and risk notes

- **Memory:** Hermes measures ~220 MB for Xvnc + Xfce and 0.5–1 GB for the headed browser; plan
  1.1–1.5 GB per open screen with a browser. The 12 GB VPS is comfortable. Hermes refuses to start
  a screen below `bot_desktop.min_free_memory_mb` (1536 by default) and the app shows why.
- **Root:** Hermes runs as root on this VPS, so the screen and its browser do too. The control lock
  is a tool-level fence on Hermes' browser/computer tools, not an OS boundary (Hermes' docs say so);
  any root process can reach the display. Treat secrets you type on it accordingly.
- **IP reputation:** the screen's browser browses from the VPS's datacenter IP. Some sites (Meta in
  particular) challenge logins from new or datacenter IPs more often. Cookies from a successful
  takeover login persist; if a site keeps challenging, a PC-hosted browser is the alternative
  (not built).

## Tests

- `Packages/HermesKit/Tests/HermesKitTests/ScreenTests.swift` — status/lease parsing, ticket URL,
  close codes, binary WebSocket frames, ordered input, clean close.
- `LiveHermesTests.testBotScreenWatchTakeOverHandBack` — against a real sshd + `hermes serve` +
  Xvnc: start the screen, read the RFB greeting through the SSH tunnel, take over (lease event
  broadcast, screenshots withheld), clean close hands back, explicit take over / hand back, a
  foreign viewer id is refused, stop. CI runs it on the Hermes-main leg with the packages installed
  (`HERMES_E2E_SCREEN=1`) and checks the 284d220 leg reports "unsupported".
- `ScreenshotTests.testScreenViewer` — the Hub entry and the screen-off state (demo mode).
