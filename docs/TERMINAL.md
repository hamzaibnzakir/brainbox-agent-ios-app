# Direct VPS terminal

This is a real interactive shell (PTY) that the app opens through the Brainbox Hermes proxy. It is reachable only over Tailscale, behind the same per-device tokens as everything else.

- **Off by default.** Two switches are needed: `[terminal] enabled = true` on the server, and `terminal = true` on the phone's `[[devices]]` entry.
- **Least privilege.** Every shell runs as one dedicated account, `brainbox-term` by default, and never as root. The proxy refuses to start if that account is root or missing.
  - The environment is rebuilt from scratch: HOME, USER, PATH, TERM and LANG only. No Hermes key, no device-token hashes and no proxy configuration are passed in.
  - The shell inherits the proxy unit's `ProtectSystem=full`, so `/usr`, `/boot` and `/etc` are read-only to it.
- **No approval step.** Ordinary commands run without one. The app warns before sending commands that look destructive, such as `rm -rf /`, `mkfs`, `dd of=/dev/…`, `shutdown` or `chmod -R 777 /`, but it doesn't block them.
- **Session handling:**
  - Resize, Ctrl-C and reconnect are all supported. A dropped connection can reattach within `detach_grace_seconds` (default 5 min), and the last 64 KB of output is replayed.
  - A shell with no input for `idle_timeout_seconds` (default 30 min) is closed.
  - Each device can have at most `max_sessions_per_device` sessions open.
- **Privacy.** Keystrokes and output are never logged. The audit log records only open, reattach, detach and close, with the device name.
- **Test status.** Tested in CI and a Linux container with a real PTY: size, `tty`, Ctrl-C, reattach, scrollback replay and the clean environment. It has **not** been tested on your VPS.

## Setup (review first — run these yourself over SSH)

```bash
# 1. The least-privilege account: no password, no sudo, its own home.
sudo useradd --create-home --shell /bin/bash --user-group brainbox-term
sudo passwd -l brainbox-term                 # no password login
id brainbox-term                             # check: not in sudo/adm/docker groups

# 2. (optional) let it read the Brainbox workspace, nothing else of the proxy's
#    sudo setfacl -R -m u:brainbox-term:rx /var/lib/brainbox-gateway/workspace

# 3. Turn it on in /etc/brainbox-gateway/hermes-proxy.toml
#    [terminal]
#    enabled = true
#    user = "brainbox-term"
#    …and on your phone's [[devices]] entry:  terminal = true
sudo /opt/brainbox-gateway/venv/bin/brainbox-gateway hermes-proxy-check --config /etc/brainbox-gateway/hermes-proxy.toml

# 4. Restart only the proxy (Hermes and the Telegram bot are separate services)
sudo systemctl restart brainbox-hermes-proxy
journalctl -u brainbox-hermes-proxy -n 30 --no-pager
```

## Rollback

```bash
# Turn it off (the shells are killed when the proxy restarts):
sudo nano /etc/brainbox-gateway/hermes-proxy.toml      # under [terminal] set: enabled = false
sudo systemctl restart brainbox-hermes-proxy
# Remove the account and its home completely:
sudo pkill -u brainbox-term || true
sudo userdel --remove brainbox-term
```

Revoking a phone (delete its `[[devices]]` entry and restart the proxy) also revokes its terminal access.
