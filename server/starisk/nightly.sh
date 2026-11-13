#!/usr/bin/env bash
#
# server/starisk/nightly.sh — the nightly Starisk run (see the repo's TODO.md).
#
# Run as the `matias` user, normally by starisk-nightly.service:
#
#     ./nightly.sh              # real run
#     ./nightly.sh --dry-run    # no queue writes, no push, crawl from cache
#
# Secrets: ~/.config/starisk/env (600, owned by matias)
#     TURSO_DATABASE_URL=libsql://...
#     TURSO_AUTH_TOKEN=...
#     NTFY_TOPIC=...            # optional; omit to stay silent
#     NTFY_URL=https://ntfy.sh  # optional
#
# Config overrides: STARISK_REPO, STARISK_MAX_AGE (days, default 7),
#                   STARISK_LIMIT (max fetches, optional)
#
set -euo pipefail

REPO=${STARISK_REPO:-$HOME/src/starisk}
ENV_FILE=${STARISK_ENV:-$HOME/.config/starisk/env}
STATE_DIR=${STARISK_STATE:-$HOME/.local/state/starisk}
MAX_AGE=${STARISK_MAX_AGE:-7}
LIMIT=${STARISK_LIMIT:-}
KEY=$HOME/.ssh/id_ed25519_starisk
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

[ -d "$REPO/.git" ] || {
  log "ERROR: $REPO is not a git clone"
  exit 1
}

if [ -r "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

NTFY_URL=${NTFY_URL:-https://ntfy.sh}

notify() {
  local title=$1 prio=$2 body=$3
  [ -n "${NTFY_TOPIC:-}" ] || return 0
  curl -s -o /dev/null --max-time 10 \
    -H "Title: $title" -H "Priority: $prio" -H "Tags: star" \
    -d "$body" "$NTFY_URL/$NTFY_TOPIC" || true
}

fail() {
  log "ERROR: $*"
  notify "starisk: failed" high "$*"
  exit 1
}

on_error() {
  notify "starisk: failed" high \
    "nightly run aborted at line $1 — journalctl -u starisk-nightly"
}
trap 'on_error $LINENO' ERR

# Pinned toolchains (mise shims), non-interactive safe.
export PATH="$HOME/.local/share/mise/shims:$PATH"
export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

cd "$REPO"

log "pulling"
git fetch --quiet origin
git merge --ff-only --quiet origin/main || fail "local clone has diverged; fix it by hand"

# --- 1. turn the request queue into crawl work ---------------------------------
if [ -n "${TURSO_DATABASE_URL:-}" ]; then
  log "demand queue"
  write_flag=""
  [ "$DRY" -eq 0 ] && write_flag="--write"
  # shellcheck disable=SC2086
  (cd pipeline && python -m starisk.demand \
    --url "$TURSO_DATABASE_URL" --token "${TURSO_AUTH_TOKEN:-}" $write_flag) 2>&1 | tail -30
elif [ "$DRY" -eq 0 ]; then
  fail "TURSO_DATABASE_URL is not set in $ENV_FILE"
else
  log "skipping demand (dry run, no Turso credentials)"
fi

# --- 2. crawl ------------------------------------------------------------------
log "crawl (max-age ${MAX_AGE}d${LIMIT:+, limit $LIMIT})"
crawl_args=(--max-age "$MAX_AGE")
[ -n "$LIMIT" ] && crawl_args+=(--limit "$LIMIT")
[ "$DRY" -eq 1 ] && crawl_args+=(--offline)

(cd pipeline &&
  python -m starisk.crawl "${crawl_args[@]}" 2>&1 | tail -20 &&
  python -m starisk.logos 2>&1 | tail -5 &&
  python -m starisk.logo_hires 2>&1 | tail -5 &&
  python -m starisk.groupings --write 2>&1 | tail -5)

# --- 3. copy data into the site ------------------------------------------------
log "web sync"
node web/scripts/sync-data.mjs 2>&1 | tail -5

# --- 4. publish ----------------------------------------------------------------
mkdir -p "$STATE_DIR"
date -Is >"$STATE_DIR/last-run"

if [ "$DRY" -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
  log "publishing"
  git add -A
  git commit -q -m "chore(data): nightly crawl $(date -u +%F)"
  git push --quiet origin HEAD:main || fail "push failed"
  summary=$(git show --stat --oneline HEAD | tail -1)
  log "pushed: $summary"
  notify "starisk: updated" default "$summary"
elif [ "$DRY" -eq 1 ]; then
  log "dry run: not committing"
else
  log "no data changes"
  notify "starisk: no changes" low "nightly run completed; nothing to publish"
fi

log "done"
