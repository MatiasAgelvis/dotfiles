#!/usr/bin/env bash
#
# scripts/close-docker-ports.sh — stop Docker-published ports bypassing ufw.
#
#     sudo ./scripts/close-docker-ports.sh          # apply
#     sudo ./scripts/close-docker-ports.sh --show   # print the rules
#
# Docker writes its own iptables rules and publishes ports on 0.0.0.0, which
# ufw never sees. This adds DOCKER-USER rules so those ports are reachable from
# the LAN and from the host itself, but not from anywhere else.
#
# Loopback traffic (cloudflared -> localhost:8000/443) is handled in OUTPUT, not
# FORWARD, so it is unaffected.
#
# Run at boot by docker-port-guard.service; safe to re-run any time.
#
set -euo pipefail

PORTS=${PORTS:-8000,8080,6001,6002}
LAN=${LAN:-192.168.0.0/16}
COMMENT='dotfiles:docker-ports'
CHAIN=DOCKER-USER

die() {
  printf '!! %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || die "run with sudo"
command -v iptables >/dev/null || die "iptables not found"

show() {
  iptables -S "$CHAIN" 2>/dev/null | grep -- "$COMMENT" || echo "  (no rules installed)"
}

if [ "${1:-}" = "--show" ]; then
  show
  exit 0
fi

# Already installed? Then there is nothing to do (idempotent).
if iptables -C "$CHAIN" -p tcp -m multiport --dports "$PORTS" \
  -m comment --comment "$COMMENT" -j DROP 2>/dev/null; then
  echo "already configured:"
  show
  exit 0
fi

echo "Installing DOCKER-USER rules for ports $PORTS (LAN: $LAN)"

# Inserted at position 1 in reverse order so the final layout is:
#   RETURN (LAN) -> DROP (everything else) -> docker's own RETURN
iptables -I "$CHAIN" 1 -p tcp -m multiport --dports "$PORTS" \
  -m comment --comment "$COMMENT" -j DROP
iptables -I "$CHAIN" 1 -p tcp -m multiport --dports "$PORTS" -s "$LAN" \
  -m comment --comment "$COMMENT" -j RETURN

# IPv6 mirrors, when the ports are published there too.
if command -v ip6tables >/dev/null 2>&1; then
  if ! ip6tables -C "$CHAIN" -p tcp -m multiport --dports "$PORTS" \
    -m comment --comment "$COMMENT" -j DROP 2>/dev/null; then
    ip6tables -I "$CHAIN" 1 -p tcp -m multiport --dports "$PORTS" \
      -m comment --comment "$COMMENT" -j DROP
  fi
fi

echo
echo "Result:"
show
echo
echo "Verify from another host on the LAN (should connect) and from outside (should time out)."
