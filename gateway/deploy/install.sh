#!/usr/bin/env bash
# Installs the Brainbox gateway next to Hermes WITHOUT touching Hermes.
#   - code + venv in /opt/brainbox-gateway
#   - config in /etc/brainbox-gateway (created only if missing)
#   - data in /var/lib/brainbox-gateway
#   - systemd unit brainbox-gateway.service (NOT started automatically)
# Run from the repo's gateway/ folder:  sudo bash deploy/install.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PY=${PYTHON:-python3}
"$PY" -c 'import sys; assert sys.version_info >= (3,10), "Python 3.10+ required"'

install -d -m 755 /opt/brainbox-gateway
install -d -m 700 /etc/brainbox-gateway /var/lib/brainbox-gateway
rsync -a --delete --exclude tests --exclude '__pycache__' "$HERE/" /opt/brainbox-gateway/src/
[ -d /opt/brainbox-gateway/venv ] || "$PY" -m venv /opt/brainbox-gateway/venv
/opt/brainbox-gateway/venv/bin/pip install -q --upgrade pip
/opt/brainbox-gateway/venv/bin/pip install -q "/opt/brainbox-gateway/src[proxy]"

if [ ! -f /etc/brainbox-gateway/gateway.toml ]; then
  install -m 600 "$HERE/deploy/gateway.example.toml" /etc/brainbox-gateway/gateway.toml
  echo
  echo "Created /etc/brainbox-gateway/gateway.toml — now run:"
  echo "  /opt/brainbox-gateway/venv/bin/brainbox-gateway new-token"
  echo "and paste the hash into [auth] token_sha256."
fi
if [ ! -f /etc/brainbox-gateway/hermes-proxy.toml ]; then
  install -m 600 "$HERE/deploy/hermes-proxy.example.toml" /etc/brainbox-gateway/hermes-proxy.toml
  echo "Created /etc/brainbox-gateway/hermes-proxy.toml (Hermes API proxy) — add a device with:"
  echo "  /opt/brainbox-gateway/venv/bin/brainbox-gateway new-device --name \"My iPhone\""
fi
install -m 644 "$HERE/deploy/brainbox-gateway.service" /etc/systemd/system/brainbox-gateway.service
install -m 644 "$HERE/deploy/brainbox-hermes-proxy.service" /etc/systemd/system/brainbox-hermes-proxy.service
systemctl daemon-reload
echo
echo "Installed. Nothing is running yet, and Hermes was not touched."
echo
echo "Hermes API proxy (the Hermes backend in the app) — docs/HERMES_API_DEPLOYMENT.md, Stage 6 onwards:"
echo "  a. /opt/brainbox-gateway/venv/bin/brainbox-gateway new-device --name \"My iPhone\"   (run over SSH, not via the agent)"
echo "  b. put the printed token_sha256 into /etc/brainbox-gateway/hermes-proxy.toml"
echo "  c. /opt/brainbox-gateway/venv/bin/brainbox-gateway hermes-proxy-check --config /etc/brainbox-gateway/hermes-proxy.toml"
echo "  d. systemctl enable --now brainbox-hermes-proxy"
echo "  e. tailscale serve --bg --https=8444 http://127.0.0.1:8766   (serve, never funnel)"
echo "     app URL: https://<this-machine>.<your-tailnet>.ts.net:8444/hermes"
echo
echo "Optional, separate: the WebSocket gateway for the app's Server tab (metrics/services/files)."
echo "Not needed for Hermes chat. Leave it stopped unless you decide to use it."
