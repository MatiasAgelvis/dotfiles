#!/usr/bin/env bash
#
# server/teardown-coolify.sh — remove Coolify, keep the origin certificate.
#
#     sudo ./server/teardown-coolify.sh          # dry run
#     sudo ./server/teardown-coolify.sh --wipe   # actually do it
#
# Destructive: removes every Coolify container, its volumes, and /data/coolify.
# The wildcard origin certificate is copied into server/traefik/certs/ first.
#
# Rollback is the nightly restic snapshot (only possible before --wipe).
#
set -euo pipefail

DOTFILES=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CERT_SRC=/data/coolify/proxy/certs
CERT_DST=$DOTFILES/server/traefik/certs
COOLIFY_DIR=/data/coolify

WIPE=0
[ "${1:-}" = "--wipe" ] && WIPE=1

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;33m!!\033[0m %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || die "run with sudo"

log "Checking certificate"
[ -f "$CERT_SRC/origin.pem" ] && [ -f "$CERT_SRC/origin.key" ] ||
  die "no origin cert at $CERT_SRC — refusing to delete anything"

if [ "$WIPE" -eq 0 ]; then
  log "DRY RUN — would:"
  echo "  copy $CERT_SRC/{origin.pem,origin.key} -> $CERT_DST/"
  echo "  stop+remove every compose stack under $COOLIFY_DIR/services"
  echo "  stop+remove the coolify stack and its volumes"
  echo "  remove $COOLIFY_DIR"
  echo
  echo "  re-run with --wipe to do it"
  exit 0
fi

log "Rescuing the origin certificate"
install -d -m 0755 "$CERT_DST"
install -m 0644 "$CERT_SRC/origin.pem" "$CERT_DST/origin.pem"
install -m 0600 "$CERT_SRC/origin.key" "$CERT_DST/origin.key"
ls -l "$CERT_DST"

log "Stopping Coolify-managed services"
for d in "$COOLIFY_DIR"/services/*/; do
  [ -f "$d/docker-compose.yml" ] || continue
  echo "  $(basename "$d")"
  docker compose -f "$d/docker-compose.yml" down --volumes --remove-orphans || true
done

log "Stopping Coolify itself"
docker compose -f "$COOLIFY_DIR/source/docker-compose.yml" down \
  --volumes --remove-orphans || true

log "Removing leftovers"
for c in coolify coolify-db coolify-redis coolify-sentinel \
  coolify-proxy coolify-proxy-error-pages; do
  docker rm -f "$c" >/dev/null 2>&1 || true
done
docker network rm coolify >/dev/null 2>&1 || true

log "Removing $COOLIFY_DIR"
rm -rf "$COOLIFY_DIR"

log "Done. Remaining containers:"
docker ps -a --format '  {{.Names}}\t{{.Status}}'
echo
echo "Next: sudo $DOTFILES/server/deploy.sh traefik"
