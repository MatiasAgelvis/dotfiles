#!/usr/bin/env bash
#
# scripts/health-check.sh — tell me when something is actually wrong.
#
#     sudo ./scripts/health-check.sh            # run the checks
#     sudo ./scripts/health-check.sh --verbose  # show passes too
#
# Pushes to ntfy only when the set of problems *changes* (new problem, or
# recovery), so a persistent issue does not notify every 15 minutes.
#
# Config: /etc/homelab-health/env
#     NTFY_TOPIC=...            # required for notifications
#     NTFY_URL=https://ntfy.sh  # optional
#     DISK_LIMIT=85             # percent
#     BACKUP_MAX_AGE_H=36       # hours
#
# Exit: 0 healthy, 1 problems.
#
set -uo pipefail

ENV_FILE=${ENV_FILE:-/etc/homelab-health/env}
STATE_DIR=${STATE_DIR:-/var/lib/homelab-health}
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

if [ -r "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi
NTFY_URL=${NTFY_URL:-https://ntfy.sh}
NTFY_TOPIC=${NTFY_TOPIC:-}
DISK_LIMIT=${DISK_LIMIT:-85}
BACKUP_MAX_AGE_H=${BACKUP_MAX_AGE_H:-36}
CLICK_URL=${CLICK_URL:-https://matiasagelvis.com}

mkdir -p "$STATE_DIR" 2>/dev/null || STATE_DIR=/tmp
STATE_FILE=$STATE_DIR/last_status

problems=()
pass() { [ "$VERBOSE" -eq 1 ] && printf '  \033[1;32mok\033[0m   %s\n' "$*"; return 0; }
fail() {
  printf '  \033[1;31mFAIL\033[0m %s\n' "$*"
  problems+=("$*")
}

# --- disk --------------------------------------------------------------------
disk=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "$disk" ] && [ "$disk" -ge "$DISK_LIMIT" ]; then
  fail "disk ${disk}% used (limit ${DISK_LIMIT}%)"
else
  pass "disk ${disk:-?}% used"
fi

# --- backup freshness --------------------------------------------------------
marker=/var/backups/homelab/manifest.txt
if [ ! -f "$marker" ]; then
  fail "no backup staged yet ($marker)"
elif find "$marker" -mmin +$((BACKUP_MAX_AGE_H * 60)) | grep -q .; then
  fail "last backup older than ${BACKUP_MAX_AGE_H}h"
else
  pass "backup staged $(find "$marker" -mmin -60 | grep -q . && echo '<1h' || echo "<=${BACKUP_MAX_AGE_H}h")"
fi

# --- containers --------------------------------------------------------------
unhealthy=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null)
if [ -n "$unhealthy" ]; then
  fail "unhealthy containers: $(echo "$unhealthy" | tr '\n' ' ')"
else
  pass "no unhealthy containers"
fi

restarting=$(docker ps --filter status=restarting --format '{{.Names}}' 2>/dev/null)
if [ -n "$restarting" ]; then
  fail "restarting containers: $(echo "$restarting" | tr '\n' ' ')"
else
  pass "nothing restarting"
fi

# --- tunnel ------------------------------------------------------------------
if systemctl is-active --quiet cloudflared 2>/dev/null; then
  pass "cloudflared active"
else
  fail "cloudflared is not active"
fi

# --- origin answers ----------------------------------------------------------
# Traefik serves /ping on its http entrypoint; 200 means the proxy is alive.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
  http://127.0.0.1/ping 2>/dev/null)
case "$code" in
  200) pass "traefik answers /ping" ;;
  *) fail "traefik /ping answered $code" ;;
esac

# --- clock -------------------------------------------------------------------
stratum=$(chronyc tracking 2>/dev/null | awk -F': *' '/^Stratum/{print $2}')
if [ "${stratum:-0}" -gt 0 ] 2>/dev/null; then
  pass "clock synced (stratum $stratum)"
else
  fail "clock not synced"
fi

# --- notify on change --------------------------------------------------------
current=$(printf '%s\n' "${problems[@]}" | sort)
previous=$(cat "$STATE_FILE" 2>/dev/null || true)

notify() {
  local title=$1 prio=$2 tags=$3 body=$4
  [ -n "$NTFY_TOPIC" ] || return 0
  curl -s -o /dev/null --max-time 10 \
    -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags" \
    -H "Click: $CLICK_URL" \
    -d "$body" "$NTFY_URL/$NTFY_TOPIC"
}

if [ "${#problems[@]}" -eq 0 ]; then
  printf '\nAll checks passed.\n'
  if [ -n "$previous" ]; then
    notify "ubuntu: recovered" default "white_check_mark" "All checks pass again."
  fi
  printf '' >"$STATE_FILE"
  exit 0
fi

printf '\n%d problem(s).\n' "${#problems[@]}"
if [ "$current" != "$previous" ]; then
  notify "ubuntu: ${#problems[@]} problem(s)" high "warning" "$current"
fi
printf '%s\n' "$current" >"$STATE_FILE"
exit 1
