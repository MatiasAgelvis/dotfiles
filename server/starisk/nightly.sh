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
BASE=${STARISK_BASE_BRANCH:-main}
BRANCH=${STARISK_BRANCH:-nightly}
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

# Commits are authored by the bot, not by matias.
export GIT_AUTHOR_NAME=${STARISK_BOT_NAME:-starisk-bot}
export GIT_AUTHOR_EMAIL=${STARISK_BOT_EMAIL:-starisk-bot@users.noreply.github.com}
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME
export GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL

cd "$REPO"

log "syncing $BRANCH from origin/$BASE"
git fetch --quiet origin
# This clone is bot-owned: every run starts from a clean origin/$BASE and
# rebuilds the bot branch. Don't edit files here by hand.
git checkout -B "$BRANCH" --quiet
git reset --hard --quiet "origin/$BASE"

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

# Refuse to publish deletions of tracked data. A parse bug that empties a file
# should fail loudly, not land on the branch (and definitely not on main).
deleted=$(git diff --name-only --diff-filter=D -- pipeline/data web/src/data || true)
if [ -n "$deleted" ]; then
  fail "refusing to publish deletions: $(echo "$deleted" | tr '\n' ' ')"
fi

if [ "$DRY" -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
  log "publishing to $BRANCH"
  git add -A
  git commit -q -m "chore(data): nightly crawl $(date -u +%F)"
  # The bot owns this branch; each run rebuilds it from $BASE.
  git push --quiet --force origin "HEAD:$BRANCH" || fail "push failed"
  summary=$(git show --stat --oneline HEAD | tail -1)
  compare="https://github.com/MatiasAgelvis/starisk/compare/$BASE...$BRANCH?expand=1"
  log "pushed: $summary"

  if [ -n "${GH_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    gh pr view "$BRANCH" --json number >/dev/null 2>&1 ||
      gh pr create --base "$BASE" --head "$BRANCH" \
        --title "chore(data): nightly crawl $(date -u +%F)" \
        --body "Automated data refresh from the homelab. Review the diff; merge to publish." \
        >/dev/null 2>&1 ||
      log "WARN: could not create the pull request (check GH_TOKEN scope)"
  fi

  notify "starisk: nightly ready" default "$summary"$'\n'"$compare"
elif [ "$DRY" -eq 1 ]; then
  log "dry run: not committing, not pushing"
else
  log "no data changes"
  notify "starisk: no changes" low "nightly run completed; nothing to publish"
fi

log "done"
