#!/usr/bin/env bash
# setup.sh — install systemd unit + nginx site for Meridian Wealth.
#
# Run on the EC2 box (Ubuntu 24.04) after cloning the repo and
# creating the venv. Idempotent: safe to re-run after pulling new
# versions of the unit / nginx files.
#
# Usage:
#   cd ~/meridian-wealth-deployment
#   sudo bash deployment/ec2/setup.sh

set -euo pipefail

APP_NAME="meridian-wealth"
REPO_DIR="/home/ubuntu/meridian-wealth-deployment"
SERVICE_SRC="${REPO_DIR}/deployment/ec2/systemd/${APP_NAME}.service"
NGINX_SRC="${REPO_DIR}/deployment/ec2/nginx/sites-available/${APP_NAME}"
SERVICE_DST="/etc/systemd/system/${APP_NAME}.service"
NGINX_DST="/etc/nginx/sites-available/${APP_NAME}"
NGINX_LINK="/etc/nginx/sites-enabled/${APP_NAME}"

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

echo "==> Installing systemd unit at ${SERVICE_DST}"
install -m 0644 "${SERVICE_SRC}" "${SERVICE_DST}"

echo "==> Reloading systemd"
systemctl daemon-reload

echo "==> Enabling ${APP_NAME}.service"
systemctl enable "${APP_NAME}.service"

echo "==> Installing nginx site at ${NGINX_DST}"
install -m 0644 "${NGINX_SRC}" "${NGINX_DST}"

echo "==> Enabling nginx site (symlink in sites-enabled)"
ln -sf "${NGINX_DST}" "${NGINX_LINK}"

echo "==> Disabling default nginx site if present"
rm -f /etc/nginx/sites-enabled/default

echo "==> Testing nginx config"
nginx -t

echo "==> Reloading nginx"
systemctl reload nginx

echo
echo "Setup complete."
echo "  Start the app:   sudo systemctl start ${APP_NAME}"
echo "  Tail logs:       sudo journalctl -u ${APP_NAME} -f"
echo "  Restart:         sudo systemctl restart ${APP_NAME}"
echo "  Status:          systemctl status ${APP_NAME}"
