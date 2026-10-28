#!/usr/bin/env bash
#
# scripts/harden-server.sh — baseline hardening for the Ubuntu homelab box.
#
#   sudo ./scripts/harden-server.sh                     # dry run, prints the plan
#   sudo ./scripts/harden-server.sh --apply             # ufw only
#   sudo ./scripts/harden-server.sh --apply --ssh-key-only   # ufw + key-only ssh
#
# Deliberate non-goals:
#   - fail2ban: near-worthless once password auth is off and only the tunnel
#     reaches sshd.
#   - PermitRootLogin no: Coolify's web terminal SSHes in as root (publickey,
#     from the coolify container), so we use prohibit-password instead.
#   - Blocking 80/443: Traefik renews certificates over the HTTP-01 challenge.
#   - Docker-published ports (8000, 6001-6002, 8080): ufw cannot see them.
#     This script reports them; closing them means changing the compose
#     bindings, not the firewall.
#
set -euo pipefail

LAN=${LAN:-192.168.0.0/16}
SSHD_CONF=/etc/ssh/sshd_config.d/99-hardening.conf
TARGET_USER=${SUDO_USER:-matias}
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

APPLY=0
SSH_KEY_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --ssh-key-only) SSH_KEY_ONLY=1 ;;
    -h | --help) sed -n '2,22p' "$0"; exit 0 ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

[ "$(id -u)" -eq 0 ] || {
  echo "Run with sudo." >&2
  exit 1
}

say() { printf '\n==> %s\n' "$*"; }
doing() { printf '  + %s\n' "$*"; }
would() { printf '  would: %s\n' "$*"; }

[ "$APPLY" -eq 1 ] || say "DRY RUN — nothing will change. Re-run with --apply."

# --- 1. ufw ------------------------------------------------------------------
say "Firewall (ufw)"
if ufw status 2>/dev/null | grep -q '^Status: active'; then
  doing "ufw already active; ensuring LAN rules exist"
else
  doing "default deny incoming / allow outgoing"
  doing "allow ssh/http/https from $LAN only"
  doing "enable ufw"
  if [ "$APPLY" -eq 1 ]; then
    ufw --force default deny incoming
    ufw --force default allow outgoing
    ufw allow from "$LAN" to any port 22 proto tcp comment 'ssh from LAN'
    ufw allow from "$LAN" to any port 80 proto tcp comment 'http from LAN'
    ufw allow from "$LAN" to any port 443 proto tcp comment 'https from LAN'
    ufw --force enable
  fi
fi

# --- 2. sshd -----------------------------------------------------------------
say "SSH (target user: $TARGET_USER)"

keys=$(find "$TARGET_HOME/.ssh" -maxdepth 1 -name 'authorized_keys' -type f 2>/dev/null | wc -l)
keycount=0
if [ "$keys" -gt 0 ]; then
  keycount=$(grep -cvE '^[[:space:]]*(#|$)' "$TARGET_HOME/.ssh/authorized_keys" || true)
fi

if [ "$keycount" -eq 0 ]; then
  printf '  !! no authorized_keys for %s — refusing to disable password auth\n' "$TARGET_USER"
elif [ "$SSH_KEY_ONLY" -eq 0 ]; then
  would "write $SSHD_CONF (PasswordAuthentication no, PermitRootLogin prohibit-password)"
  would "validate with sshd -t and reload (add --ssh-key-only to apply)"
else
  doing "write $SSHD_CONF"
  doing "reload sshd"
  if [ "$APPLY" -eq 1 ]; then
    cat >"$SSHD_CONF" <<'EOF'
# Managed by dotfiles/scripts/harden-server.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
EOF
    sshd -t
    systemctl reload ssh
  fi
fi

# --- 3. docker-published ports (report only) ---------------------------------
say "Docker-published ports (not covered by ufw)"
docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null |
  grep -E '0\.0\.0\.0|:::' || echo "  none"

say "Done. Verify from a second terminal before closing the current one."
if [ "$APPLY" -eq 1 ]; then
  echo "  sudo ufw status verbose"
  echo "  ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no $TARGET_USER@<host> true"
fi
