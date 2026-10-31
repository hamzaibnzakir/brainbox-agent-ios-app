# Connecting Brainbox to your VPS (SSH, like Hermes Desktop)

Brainbox 2 talks to Hermes the same way Hermes Desktop's SSH mode does: the phone
opens an SSH connection, starts (or reuses) `hermes serve` on the server, and
speaks Hermes' own gateway protocol through that SSH connection. Nothing new is
installed on the server and no extra port is opened — only SSH (port 22).

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
- **Notifications**: local notifications when a reply lands or Hermes needs
  approval; approve or deny right from the banner.
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
