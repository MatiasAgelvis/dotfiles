#!/usr/bin/env bash
#
# scripts/net-check.sh — local network triage for this box.
#
#     ./scripts/net-check.sh                    # full report
#     ./scripts/net-check.sh affine.example.com # ...plus a tunnel hostname test
#
# Needs no root. Every probe has a timeout, so it works when the box is offline.
# Exit code: 0 = healthy, 1 = at least one FAIL, 2 = degraded (warnings only).
#
set -uo pipefail

TUNNEL_HOST=${1:-}
PASS=0
FAIL=0
WARN=0

have() { command -v "$1" >/dev/null 2>&1; }
pass() { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[1;33mWARN\033[0m %s\n' "$*"; WARN=$((WARN + 1)); }
info() { printf '       %s\n' "$*"; }
section() { printf '\n\033[1m── %s\033[0m\n' "$*"; }

# Physical NICs only: /sys/class/net/*/device exists for real hardware.
phys_ifaces() {
  local d
  for d in /sys/class/net/*; do
    [ -e "$d/device" ] && basename "$d"
  done
}

upstream_ok() {
  ping -I "$1" -c1 -W2 -q 1.1.1.1 >/dev/null 2>&1
}

# ── interfaces ────────────────────────────────────────────────────────────────
section "Interfaces"
IFACES=$(phys_ifaces)
[ -n "$IFACES" ] || fail "no physical interfaces found"
for i in $IFACES; do
  state=$(cat "/sys/class/net/$i/operstate" 2>/dev/null || echo unknown)
  carrier=$(cat "/sys/class/net/$i/carrier" 2>/dev/null || echo "?")
  v4=$(ip -4 -o addr show dev "$i" scope global 2>/dev/null | awk '{print $4}')
  v6=$(ip -6 -o addr show dev "$i" scope global 2>/dev/null | awk '{print $4}' | head -1)
  metric=$(ip route show default dev "$i" 2>/dev/null | awk '{print $NF}')

  printf '  %s: %s' "$i" "$state"
  [ "$carrier" = "0" ] && printf ' (no carrier)'
  printf '\n'
  info "ipv4: ${v4:-none}   ipv6: ${v6:-none}   default metric: ${metric:-none}"

  if [ "$state" = "up" ] && [ -n "$v4" ]; then
    pass "$i configured"
  else
    fail "$i not configured ($state)"
  fi

  if [ "$state" = "up" ] && [ -n "$v4" ]; then
    if upstream_ok "$i"; then
      info "$i reaches the internet"
    else
      info "$i has NO upstream (fine if it's a local-only network)"
    fi
  fi

  if [ -d "/sys/class/net/$i/wireless" ] && have iw; then
    iw dev "$i" link 2>/dev/null | awk '
      /SSID:/        {printf "       wifi: %s\n", $0}
      /freq:/        {printf "       %s\n", $0; }
      /signal:/      {printf "       %s\n", $0}
      /bitrate:/     {printf "       %s\n", $0}'
    sig=$(iw dev "$i" link 2>/dev/null | awk '/signal:/{print $2}')
    if [ -n "$sig" ] && [ "${sig:-0}" -lt -75 ] 2>/dev/null; then
      warn "$i signal is weak (${sig} dBm)"
    fi
  fi
done

# ── routing ───────────────────────────────────────────────────────────────────
section "Routing"
DEFAULTS=$(ip route show default)
if [ -z "$DEFAULTS" ]; then
  fail "no default route"
else
  echo "$DEFAULTS" | sed 's/^/       /'
  best=$(echo "$DEFAULTS" | awk '{print $NF"|"$0}' | sort -n | head -1 |
    cut -d'|' -f2 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
  pass "default route present (preferred: ${best:-unknown})"
  sel=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
  info "1.1.1.1 goes out $sel"

  # The interesting case: preferred iface has no upstream, another one does.
  if [ -n "$sel" ] && ! upstream_ok "$sel"; then
    fail "preferred interface $sel has no upstream"
    for i in $IFACES; do
      [ "$i" = "$sel" ] && continue
      if upstream_ok "$i"; then
        warn "$i DOES have upstream — route metrics likely wrong"
      fi
    done
  elif [ -n "$sel" ]; then
    pass "preferred interface $sel reaches the internet"
  fi
fi

# ── dns ───────────────────────────────────────────────────────────────────────
section "DNS"
if have resolvectl; then
  mode=$(resolvectl status 2>/dev/null | awk -F': ' '/resolv.conf mode/{print $2}')
  info "resolv.conf mode: ${mode:-unknown}"
  resolvectl status 2>/dev/null | awk '/Current DNS Server:/{print "       " $0}' | head -3
fi
for host in one.one.one.one cloudflare.com; do
  if timeout 5 getent hosts "$host" >/dev/null 2>&1; then
    pass "resolve $host"
  else
    fail "cannot resolve $host"
  fi
done

# ── connectivity ladder ───────────────────────────────────────────────────────
section "Connectivity"
gw=$(echo "$DEFAULTS" | head -1 | awk '{print $3}')
if [ -n "$gw" ]; then
  if ping -c1 -W2 -q "$gw" >/dev/null 2>&1; then
    pass "gateway $gw reachable"
  else
    fail "gateway $gw unreachable"
  fi
fi

if ping -c1 -W2 -q 1.1.1.1 >/dev/null 2>&1; then
  pass "ICMP 1.1.1.1"
else
  fail "ICMP 1.1.1.1"
fi

if timeout 5 bash -c '</dev/tcp/1.1.1.1/443' 2>/dev/null; then
  pass "TCP 1.1.1.1:443"
else
  fail "TCP 1.1.1.1:443"
fi

if have curl; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://www.cloudflare.com/ 2>/dev/null)
  if [ "$code" = "200" ]; then
    pass "HTTPS cloudflare.com (200)"
  else
    fail "HTTPS cloudflare.com (${code:-no response})"
  fi
fi

# ── clock ─────────────────────────────────────────────────────────────────────
section "Clock"
if have chronyc; then
  stratum=$(chronyc tracking 2>/dev/null | awk -F': *' '/^Stratum/{print $2}')
  if [ "${stratum:-0}" -gt 0 ] 2>/dev/null; then
    pass "NTP synchronised (stratum $stratum)"
  else
    warn "chrony NOT synchronised (stratum ${stratum:-?}) — run: chronyc sources"
  fi
elif have timedatectl; then
  synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  if [ "$synced" = "yes" ]; then
    pass "clock synchronised"
  else
    warn "clock not synchronised — breaks TLS and tunnel auth"
  fi
fi
info "$(date -Is)"

# ── tunnel ────────────────────────────────────────────────────────────────────
section "Tunnel"
if systemctl is-active --quiet cloudflared 2>/dev/null; then
  pass "cloudflared.service active"
else
  fail "cloudflared.service not active"
fi
if [ -n "$TUNNEL_HOST" ] && have curl; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$TUNNEL_HOST/" 2>/dev/null)
  case "$code" in
    2?? | 3??) pass "https://$TUNNEL_HOST -> $code" ;;
    000 | "") fail "https://$TUNNEL_HOST unreachable" ;;
    *) warn "https://$TUNNEL_HOST -> $code" ;;
  esac
fi

# ── recent logs ───────────────────────────────────────────────────────────────
section "Recent network warnings (30 min)"
if have journalctl; then
  out=$(journalctl -u systemd-networkd -u wpa_supplicant -u cloudflared \
    --since '-30 min' -p warning --no-pager 2>/dev/null | grep -v '^-- No entries --$' | tail -12)
  if [ -n "$out" ]; then
    echo "$out" | sed 's/^/       /'
    warn "warnings present in network logs"
  else
    pass "no recent warnings"
  fi
fi

# ── summary ───────────────────────────────────────────────────────────────────
printf '\n\033[1m── Summary\033[0m\n'
printf '  %d passed, %d failed, %d warnings\n' "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -gt 0 ]; then
  echo "  Not healthy. Start with: systemctl status systemd-networkd wpa_supplicant cloudflared"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo "  Working, but worth a look at the warnings above."
  exit 2
else
  echo "  All good."
  exit 0
fi
