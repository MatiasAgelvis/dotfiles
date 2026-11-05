#!/usr/bin/env bash
#
# scripts/install-health.sh — install the health checks + ntfy alerts.
#
#     sudo ./scripts/install-health.sh
#
# Idempotent. On first run it generates a random ntfy topic and prints the URL
# to subscribe to; the topic is the only secret (anyone with it can read the
# alerts, so treat it like a password).
#
set -euo pipefail

DOTFILES=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=${ENV_FILE:-/etc/homelab-health/env}
NTFY_URL=${NTFY_URL:-https://ntfy.sh}

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;33m!!\033[0m %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || die "run with sudo"

log "Installing health check + units"
install -d -m 0755 /etc/homelab-health
install -d -m 0755 /var/lib/homelab-health
install -m 0755 "$DOTFILES/scripts/health-check.sh" /usr/local/bin/homelab-health-check
install -m 0644 "$DOTFILES/systemd/homelab-health.service" \
  "$DOTFILES/systemd/homelab-health.timer" /etc/systemd/system/

if [ ! -f "$ENV_FILE" ]; then
  topic="homelab-$(openssl rand -hex 12)"
  cat >"$ENV_FILE" <<EOF
# ntfy topic — treat like a password; anyone with it can read the alerts.
NTFY_TOPIC=$topic
NTFY_URL=https://ntfy.sh
DISK_LIMIT=85
BACKUP_MAX_AGE_H=36
EOF
  chmod 600 "$ENV_FILE"
  log "Created $ENV_FILE"
else
  log "Keeping existing $ENV_FILE"
fi

# Always print the subscription details, whether we just created the file or not.
# shellcheck disable=SC1090
. "$ENV_FILE"
if [ -n "${NTFY_TOPIC:-}" ]; then
  printf '\n  Subscribe on your phone (ntfy app) to:\n\n      %s\n\n  or open: %s\n\n' \
    "${NTFY_URL:-https://ntfy.sh}/${NTFY_TOPIC}" "${NTFY_URL:-https://ntfy.sh}/${NTFY_TOPIC}"
else
  printf '\n  !! NTFY_TOPIC is empty in %s — no alerts will be sent\n\n' "$ENV_FILE"
fi

systemctl daemon-reload
systemctl enable --now homelab-health.timer

log "First run"
/usr/local/bin/homelab-health-check --verbose || true

log "Schedule"
systemctl list-timers homelab-health.timer --no-pager | head -3
