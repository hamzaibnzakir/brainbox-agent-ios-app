# Release candidate: deploy, verify, roll back

This covers branch `feature/full-stack-upgrade`. Nothing in it has been run on your VPS. Every server command below is for **you** to review and run over SSH. They only touch the Brainbox proxy, never Hermes, Telegram or cron jobs. The one exception is Stage 4 of `HERMES_API_DEPLOYMENT.md`, if the API server isn't enabled yet.

## 0. What needs to be on the server

| Need | Why | Status on your VPS (per the last audit) |
| --- | --- | --- |
| Hermes API server enabled (`API_SERVER_KEY`, loopback) | Everything in the app | Not running yet (audit), so do `HERMES_API_DEPLOYMENT.md` Stages 0–4 first |
| Tailscale | Private access, never public | Not installed yet (Stage 2) |
| Brainbox proxy from this branch | Chat delete/archive, files, terminal, commands, server overview | Not installed |
| `brainbox-term` account | Terminal only | Optional (`docs/TERMINAL.md`) |

## 1. Install or update the proxy (review first)

```bash
# On the VPS, from a checkout of this branch:
cd brainbox-agent-ios-app/gateway
sudo bash deploy/install.sh                       # code → /opt/brainbox-gateway; config only created if missing; starts nothing
sudo /opt/brainbox-gateway/venv/bin/brainbox-gateway hermes-proxy-check --config /etc/brainbox-gateway/hermes-proxy.toml
```

If you already had a `hermes-proxy.toml`, compare it with `deploy/hermes-proxy.example.toml` and add the new sections:

- `[files]`
- `[terminal]` (keep `enabled = false` until you've made the account)
- `state_dir`

Then restart **only** the proxy:

```bash
sudo systemctl restart brainbox-hermes-proxy
journalctl -u brainbox-hermes-proxy -n 40 --no-pager
```

**Rollback:** `sudo systemctl stop brainbox-hermes-proxy`. Hermes and Telegram keep running untouched. To remove the proxy completely:

```bash
sudo systemctl disable --now brainbox-hermes-proxy
sudo rm -rf /opt/brainbox-gateway
```

Keep `/etc/brainbox-gateway` and `/var/lib/brainbox-gateway`; they hold your device tokens, the chat-ownership registry and the workspace.

## 2. Install the app

- **IPA:** download it from the CI run's artifact `BrainboxAgent-unsigned-ipa` and sideload it as before.
- **Settings → Hermes:** set the proxy URL `https://<vps>.<tailnet>.ts.net/hermes` and the device token.
- **Notifications:** Settings → Notifications → **Allow**, then **Send a test notification**.

## 3. Manual checks on the real VPS

Run these in order. ✅ marks what a pass looks like. None of them touch Telegram chats or existing scheduled jobs. Use a **new test chat** and a **new test job**, and delete them when done.

| # | Feature | Steps | Pass |
| --- | --- | --- | --- |
| 1 | Connection | Open Home. | ✅ "Hermes · Responding · NN ms" and real host facts under Server. |
| 2 | Chat + stream | New chat → "Count slowly from 1 to 30, one number per line." | ✅ Text streams in. |
| 3 | **Stop** | During #2, tap Stop. | ✅ "Stop requested…" then "Hermes is stopping it…", then "Stopped — Hermes confirmed". Tasks shows the run as cancelled. |
| 4 | Stop a shell command | "Run `sleep 120` in the terminal tool, then say done." Approve if asked, then Stop. | ✅ It stops within seconds. Hermes reaps that run's process; `ps aux \| grep "sleep 120"` on the VPS shows nothing. |
| 5 | Steer | Start a long task, type "Focus only on errors", tap ↪ (Steer now). | ✅ "Steering sent". The reply changes course. |
| 6 | Queue / Stop and send | Hold ↪ → "Send after this" / "Stop and send". | ✅ The queued line appears above the composer and is sent when the reply ends, or after the confirmed stop. |
| 7 | Slash commands | Type `/`. | ✅ The suggestion list shows APP / SKILL / CLI ONLY items. |
| 8 | Commands | Try `/help`, `/status`, `/model`, then `/compress`. | ✅ The first three show local cards. `/compress` explains it's CLI-only, and nothing reaches Hermes. |
| 9 | Skill command | Try `/<one of your skills> do X`. | ✅ The bubble says "Ran as a Hermes skill" and the agent follows the skill. |
| 10 | Image to model | Use a vision-capable model. Tap + → Photo → "What's in this photo?" | ✅ The attachment shows "Sent with message" and the reply describes the photo. (A non-vision model will say it can't see images.) |
| 11 | File to agent | Tap + → File (a .txt) → "Summarise this file". | ✅ It uploads with a progress bar, then shows "On your server", and the agent reads the path it's given. |
| 12 | Files screen | Server → Files → Inbox. | ✅ The uploaded file is there. Download → preview opens, and Delete works. |
| 13 | Parallel agents | Workspace → Parallel agents → New, with 3 short tasks → Start. | ✅ Three cards run at the same time, each with its own run id. |
| 14 | Isolated cancel | During #13, Stop agent 2. | ✅ Only agent 2 ends as "Stopped"; the others finish. Then "Combined result" runs and mentions agent 2 was stopped. |
| 15 | Scheduled tasks | Create a test job, run it once (Run now), then delete it. | ✅ The run goes queued → running → completed, the result opens, and deletion warns first. |
| 16 | Archive / restore | History → swipe a test chat → Archive → Archived chats → Restore. | ✅ It persists after force-quit and relaunch. |
| 17 | Delete permanently | Delete the test chat. | ✅ "Deleted from this device and from your server". It stays absent after relaunch, and from another phone with its own token. |
| 18 | Telegram safety | Sessions → a Telegram chat. | ✅ Read-only. Delete and Archive aren't offered; "Continue" makes a copy. |
| 19 | Terminal | Only if set up: Server → Terminal → Open. Run `whoami; stty size`, rotate the phone, then `top` and Ctrl-C. | ✅ `brainbox-term`, a real size that changes on rotate, and `top` stops. Leaving and coming back reattaches. |
| 20 | Notifications | Start a long task, go to the Home Screen. | ✅ A "Task finished" alert arrives if it ends within about 30 s; a later finish is announced at the next background check. A test job finishing while the app is open shows an alert. |

Report anything that fails with the screen, the time, and `journalctl -u brainbox-hermes-proxy --since "10 min ago"`. That log never contains message content.
