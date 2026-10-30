#!/usr/bin/env bash
#
# scripts/install-backup.sh — install or upgrade the nightly backup job.
#
#   sudo ./scripts/install-backup.sh          # install, enable timer
#   sudo ./scripts/install-backup.sh --run    # ...and run a backup immediately
#
# Idempotent: re-run after editing scripts/backup.sh or the systemd units.
# It never prints secret values, and it refuses to enable the timer when
# /etc/restic/env is missing or incomplete.
#
set -euo pipefail

DOTFILES=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE=${ENV_FILE:-/etc/restic/env}
RUN_NOW=0
[ "${1:-}" = "--run" ] && RUN_NOW=1

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() {
  warn "$*"
  exit 1
}

[ "$(id -u)" -eq 0 ] || die "run with sudo"

# --- 1. packages -------------------------------------------------------------
missing=()
for pkg in restic sqlite3; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' ||
    missing+=("$pkg")
done
if ((${#missing[@]})); then
  log "Installing: ${missing[*]}"
  apt-get update -qq
  apt-get install -y --no-install-recommends "${missing[@]}"
else
  log "restic and sqlite3 already installed"
fi

# --- 2. credentials ----------------------------------------------------------
HAVE_ENV=1
if [ ! -r "$ENV_FILE" ]; then
  HAVE_ENV=0
  warn "missing $ENV_FILE — installing files, but leaving the timer disabled"
elif ! grep -qE '^[[:space:]]*RESTIC_REPOSITORY=.+' "$ENV_FILE" ||
  ! grep -qE '^[[:space:]]*RESTIC_PASSWORD=.+' "$ENV_FILE" ||
  ! grep -qE '^[[:space:]]*AWS_ACCESS_KEY_ID=.+' "$ENV_FILE" ||
  ! grep -qE '^[[:space:]]*AWS_SECRET_ACCESS_KEY=.+' "$ENV_FILE"; then
  HAVE_ENV=0
  warn "$ENV_FILE is missing one of RESTIC_REPOSITORY / RESTIC_PASSWORD /"
  warn "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY — timer left disabled"
fi

# --- 3. files ----------------------------------------------------------------
log "Installing script and units"
install -m 0755 "$DOTFILES/scripts/backup.sh" /usr/local/bin/homelab-backup
install -m 0644 "$DOTFILES/systemd/homelab-backup.service" \
  "$DOTFILES/systemd/homelab-backup.timer" /etc/systemd/system/
install -d -m 0700 /var/backups/homelab
chmod 700 /var/backups/homelab
systemctl daemon-reload

# --- 4. schedule -------------------------------------------------------------
if [ "$HAVE_ENV" -eq 1 ]; then
  log "Enabling timer"
  systemctl enable --now homelab-backup.timer
  systemctl list-timers homelab-backup.timer --no-pager | head -3
else
  log "Not enabling the timer until $ENV_FILE is complete"
fi

# --- 5. optional immediate run ----------------------------------------------
if [ "$RUN_NOW" -eq 1 ] && [ "$HAVE_ENV" -eq 1 ]; then
  log "Running a backup now"
  systemctl start homelab-backup.service
  journalctl -u homelab-backup -n 15 --no-pager
elif [ "$RUN_NOW" -eq 1 ]; then
  warn "Skipping the run: credentials are incomplete"
fi

log "Done."
