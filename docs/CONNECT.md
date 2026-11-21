# Connecting Brainbox to your VPS (SSH, like Hermes Desktop)

Brainbox 2 talks to Hermes the same way Hermes Desktop's SSH mode does: the phone
opens an SSH connection, starts (or reuses) `hermes serve` on the server, and
speaks Hermes' own gateway protocol through that SSH connection. Nothing new is
installed on the server and no extra port is opened — only SSH (port 22).

## Recommended: Tailscale mode

Hermes runs as a small service on the server (`brainbox-hermes`) that listens **only on
127.0.0.1** with a fixed access token; `tailscale serve` forwards your private tailnet to it.
The phone and the PC then talk to Hermes **directly over Tailscale** — no SSH handshake on
every (re)connect, and the connection survives Wi-Fi ↔ cellular switches because the address
never changes. Nothing is opened to the public internet; your Telegram gateway, cron jobs and
Hermes config are untouched. Both devices share the one service, so a chat is live on both.

1. **Server (once, as root):** install Tailscale and sign in —
   `curl -fsSL https://tailscale.com/install.sh | sh && tailscale up` — then run
   [`scripts/tailscale/setup-vps.sh`](../scripts/tailscale/setup-vps.sh) (also copyable from the
   app: Connection → Tailscale → *Copy setup script*). It prints the **address**, **port** (8766)
   and **token**. Re-running it is safe. Undo instructions are at the top of the script.
2. **Phone and PC:** install the Tailscale app, sign in with the same account, keep it on.
3. **Brainbox → Settings → Connection → Tailscale:** paste the address, token and port, Connect.
4. Optional (terminal, file transfers, Hermes' browser): also do the *Let this phone in* step —
   those features still use SSH, over Tailscale, opened only when you use them.

If Brainbox says it can't reach Hermes over Tailscale, check the Tailscale app is on (phone/PC)
and on the server: `systemctl status brainbox-hermes` and `tailscale serve status`.
"Hermes refused the access token" means paste it again from `cat /etc/brainbox/token`.

The SSH mode below still works without Tailscale.

## 1. Install the app

1. Download `BrainboxAgent-unsigned-ipa` from the CI run and unzip it.
2. Install `BrainboxAgent-unsigned.ipa` with Sideloadly, AltStore or SideStore
   using your Apple ID (free accounts work; the install lasts 7 days, then
   re-install).

## 2. Pair the phone (once)

1. Open Brainbox. Fill in **Host or IP** (your VPS address), **User** `root`,
   **Port** `22`.
2. Under **Let this phone in**, tap **Copy command**. It looks like:

   ```sh
   mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo 'ssh-ed25519 AAAA… brainbox-iphone' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
   ```

3. Run it on the VPS as root (paste it into the SSH session you already use, or
   any console). This only adds the phone's **public** key; the private key was
   generated on the phone and never leaves its Keychain.
4. Back in the app, tap **Connect**. The first connection trusts the server's SSH
   host key and remembers it; if it ever changes, Brainbox refuses to connect
   until you confirm (that protects against someone impersonating the server).

What happens on the server when you connect:

- Brainbox finds `hermes` (login PATH, `~/.local/bin`, `~/.hermes/hermes-agent`).
- It starts `hermes serve --isolated --host 127.0.0.1 --port 0` detached, with a
  one-shot session token passed through a private file in
  `~/.hermes/desktop-ssh/<phone-id>/` (Hermes reads and deletes it).
- The backend listens on **127.0.0.1 only**; the phone reaches it through the SSH
  connection. Next time, Brainbox reuses the same backend.
- Unlike Desktop, Brainbox does **not** run it in Desktop mode, so it never starts
  a second cron scheduler or touches your running Telegram gateway.

## 3. Using it

- **Chat**: full Hermes — your persona, every slash command, approvals, clarify
  questions, sub-agents, `/btw`, `/bg`, model switching. If the connection drops,
  Brainbox reconnects and replays what it missed.
- **Sessions**: everything Hermes has, from every app. Telegram and cron chats
  open read-only.
- **Agents**: scheduled jobs (create from blueprints, pause, run now) and live
  sub-agents (watch, steer, stop).
- **Hub**: terminal (a real root shell over SSH), files, server health, logs,
  skills, tools, MCP, memory, star map, persona, messaging, webhooks, pairing,
  models, profiles, usage, plugins, updates/doctor, code review, backups, import.
- **Hermes' screen** (Hub, or the chat menu): watch the bot's browser live,
  **Take over** for a login, CAPTCHA, 2FA or payment step, then **Hand back**.
  Needs a Hermes version with Bot Screen and its packages on the server — see
  [BOT_SCREEN.md](BOT_SCREEN.md).
- **Notifications**: local notifications when a reply lands or Hermes needs
  approval; approve or deny right from the banner. When Hermes stops at a step
  only you can do on its screen, the notification opens the screen.
- **Siri / widgets**: "Ask Brainbox", "Talk to Hermes in Brainbox"; home-screen
  widget; Live Activity while a turn runs.

## Security notes

- The key gives the phone a shell as the user you authorized (root here). Turn on
  **Settings › Security › Face ID for SSH key and terminal** so the key can't be
  used without you.
- To revoke the phone: delete its line (ending in `brainbox-…`) from
  `~/.ssh/authorized_keys` on the server.
- Gateway start/stop/restart, config edits and Hermes updates always ask for
  confirmation and Face ID.

## Limits

- Free Apple account: no remote push (Brainbox uses local notifications instead;
  while the app is closed iOS wakes it occasionally to check), no CarPlay, and
  sideloaded installs expire after 7 days.
- iOS suspends network connections in the background. Runs keep going on the
  server; Brainbox catches up when you return.
- Live voice uses push-to-talk / hands-free conversation through Hermes' own
  speech endpoints (`/api/audio/transcribe`, `/api/audio/speak`). The WebRTC
  realtime mode and wake word are not in this build.
