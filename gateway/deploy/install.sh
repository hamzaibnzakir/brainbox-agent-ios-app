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
/opt/brainbox-gateway/venv/bin/pip install -q /opt/brainbox-gateway/src

if [ ! -f /etc/brainbox-gateway/gateway.toml ]; then
  install -m 600 "$HERE/deploy/gateway.example.toml" /etc/brainbox-gateway/gateway.toml
  echo
  echo "Created /etc/brainbox-gateway/gateway.toml — now run:"
  echo "  /opt/brainbox-gateway/venv/bin/brainbox-gateway new-token"
  echo "and paste the hash into [auth] token_sha256."
fi
install -m 644 "$HERE/deploy/brainbox-gateway.service" /etc/systemd/system/brainbox-gateway.service
systemctl daemon-reload
echo
echo "Installed. Nothing is running yet. Next:"
echo "  1. /opt/brainbox-gateway/venv/bin/brainbox-gateway check --config /etc/brainbox-gateway/gateway.toml"
echo "  2. systemctl enable --now brainbox-gateway"
echo "  3. expose privately: tailscale serve --bg --https=443 http://127.0.0.1:8765"
