#!/usr/bin/env bash
#
# server/deploy.sh — bring a stack up, or update it.
#
#     sudo ./server/deploy.sh traefik
#     sudo ./server/deploy.sh <stack> logs
#
# Stacks live in server/<stack>/ with a docker-compose.yml.
#
set -euo pipefail

STACK=${1:-traefik}
ACTION=${2:-up}
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/"$STACK"

die() {
  printf '!! %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -f "$DIR/docker-compose.yml" ] || die "no stack named '$STACK' in $(dirname "$DIR")"

cd "$DIR"

case "$ACTION" in
  up | "")
    echo "==> pulling images"
    docker compose pull
    echo "==> starting"
    docker compose up -d
    docker compose ps
    ;;
  down)
    docker compose down
    ;;
  logs)
    exec docker compose logs -f --tail=100
    ;;
  ps)
    docker compose ps
    ;;
  restart)
    docker compose restart
    ;;
  *)
    die "unknown action: $ACTION (up|down|logs|ps|restart)"
    ;;
esac
