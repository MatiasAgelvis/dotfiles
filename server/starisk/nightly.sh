#!/usr/bin/env bash
#
# server/starisk/nightly.sh — host wrapper around the containerised runner.
#
#     ./nightly.sh                 # real run
#     ./nightly.sh --dry-run       # config, connectivity, smoke; no writes
#     ./nightly.sh --limit 10      # smaller crawl
#     ./nightly.sh --no-push       # commit on data/crawl, don't push
#
# The decisions live in the repo (pipeline/starisk/nightly.py); the container
# supplies python/node/git, and this script supplies ntfy and the exit-code to
# alert mapping. Docker needs root (matias is not in the docker group), so this
# runs as root from starisk-nightly.service.
#
# Exit codes are the runner's: 0 ok, 10 nothing, 20 gate, 30 partial,
# 40 git, 50 smoke, 60 config, 70 failed.
#
set -euo pipefail

COMPOSE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMPOSE="docker compose -f $COMPOSE_DIR/docker-compose.yml"
ENV_FILE=${STARISK_ENV:-/home/matias/.config/starisk/env}
STATE_DIR=${STARISK_STATE:-/home/matias/.local/state/starisk}
RECORD=$STATE_DIR/last-run.json

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

field() {
  [ -f "$RECORD" ] || return 0
  python3 - "$RECORD" "$1" <<'PY' 2>/dev/null || true
import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception:
    pass
PY
}

docker image inspect starisk-nightly:latest >/dev/null 2>&1 || {
  echo "!! image missing — build it first:" >&2
  echo "   sudo $COMPOSE build nightly" >&2
  exit 60
}

mkdir -p "$STATE_DIR"

set +e
# shellcheck disable=SC2086
$COMPOSE run --rm nightly "$@"
code=$?
set -e

reason=$(field reason)
commit=$(field commit)
pr=$(field pullRequest)
detail=${reason:-unknown}
[ -n "$commit" ] && detail="$detail (commit $commit)"
[ -n "$pr" ] && detail="$detail — $pr"

case "$code" in
  0) notify "starisk: ok" default "$detail" ;;
  10) : ;; # nothing changed: silent by design; health check watches freshness
  30) notify "starisk: partial" default "$detail" ;;
  20 | 40 | 50 | 60 | 70) notify "starisk: $(field status)" high "$detail" ;;
  *) notify "starisk: unexpected exit $code" high "$detail" ;;
esac

exit "$code"
