#!/usr/bin/env bash
# Brainbox over Tailscale — run once on the server (as root).
#
# Runs Hermes as a service that listens ONLY on 127.0.0.1, with a fixed access token, and lets
# Tailscale forward your tailnet to it. Nothing is opened to the public internet. Your Telegram
# gateway, cron jobs and Hermes config are not touched. Run it again any time: it's idempotent.
#
# Undo:  systemctl disable --now brainbox-hermes; tailscale serve reset; rm -rf /etc/brainbox \
#        /etc/systemd/system/brainbox-hermes.service
set -euo pipefail
PORT="${BRAINBOX_PORT:-8766}"

command -v tailscale >/dev/null || { echo "Install Tailscale first:  curl -fsSL https://tailscale.com/install.sh | sh  &&  tailscale up"; exit 1; }
tailscale ip -4 >/dev/null 2>&1 || { echo "Tailscale isn't signed in yet: run  tailscale up  and open the link it prints."; exit 1; }
[ "$(id -u)" = 0 ] || { echo "Run this as root (sudo -i first)."; exit 1; }

HERMES=""
for c in "$(command -v hermes || true)" "$HOME/.local/bin/hermes" "$HOME/.hermes/hermes-agent/venv/bin/hermes" \
         "$HOME/.hermes/hermes-agent/.venv/bin/hermes" /usr/local/bin/hermes /opt/hermes/bin/hermes; do
  if [ -n "$c" ] && [ -x "$c" ]; then HERMES="$c"; break; fi
done
[ -n "$HERMES" ] || { echo "Can't find the hermes command."; exit 1; }

# The access token: created once, kept private (only root can read it).
install -d -m 700 /etc/brainbox
if [ ! -s /etc/brainbox/token ]; then
  (umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > /etc/brainbox/token)
fi
(umask 077; printf 'HERMES_DASHBOARD_SESSION_TOKEN=%s\n' "$(cat /etc/brainbox/token)" > /etc/brainbox/hermes.env)

cat > /etc/systemd/system/brainbox-hermes.service <<EOF
[Unit]
Description=Hermes for Brainbox (127.0.0.1 only; reached over Tailscale)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
User=root
WorkingDirectory=$HOME
Environment=HOME=$HOME
EnvironmentFile=/etc/brainbox/hermes.env
ExecStart=$HERMES serve --isolated --host 127.0.0.1 --port $PORT
Restart=always
RestartSec=2
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable brainbox-hermes >/dev/null 2>&1
systemctl restart brainbox-hermes

# Tailscale forwards tailnet port $PORT to the service (tailnet devices only).
tailscale serve --bg --tcp "$PORT" "tcp://127.0.0.1:$PORT" >/dev/null

# The backend Brainbox used to start over SSH is no longer needed.
LOCK="$HOME/.hermes/desktop-ssh/9bfaf1f3f5d1b43167520d9fb4c60c03/brainbox-mobile.lock.json"
if [ -f "$LOCK" ]; then
  PID=$(sed -n 's/.*"pid" *: *\([0-9]*\).*/\1/p' "$LOCK"); NONCE=$(sed -n 's/.*"nonce" *: *"\([0-9a-f]*\)".*/\1/p' "$LOCK")
  if [ -n "$PID" ] && [ -n "$NONCE" ] && { tr '\0' ' ' < "/proc/$PID/cmdline"; } 2>/dev/null | grep -q -- "$NONCE"; then kill "$PID" 2>/dev/null || true; fi
fi

printf 'Waiting for Hermes'
for _ in $(seq 1 90); do
  if curl -fs -m 2 -o /dev/null -H "X-Hermes-Session-Token: $(cat /etc/brainbox/token)" "http://127.0.0.1:$PORT/api/skills"; then OK=1; break; fi
  printf '.'; sleep 1
done
echo
[ "${OK:-}" = 1 ] || { echo "Hermes didn't come up — see: journalctl -u brainbox-hermes -n 40"; exit 1; }

NAME=$(tailscale status --self --peers=false 2>/dev/null | awk 'NR==1{print $2}')
echo
echo "Brainbox is ready over Tailscale. In the app: Settings → Connection → Tailscale"
echo "  Address : $(tailscale ip -4 | head -1)${NAME:+   (or $NAME)}"
echo "  Port    : $PORT"
echo "  Token   : $(cat /etc/brainbox/token)"
echo "Keep the token private. To see it again:  cat /etc/brainbox/token"
