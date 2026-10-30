#!/usr/bin/env bash
#
# scripts/restore-test.sh — prove the latest snapshot actually restores.
#
#     sudo ./scripts/restore-test.sh
#
# Restores the newest snapshot into throwaway Postgres containers (no ports
# published, live services untouched) and checks schema + row counts against
# the running databases. Cleans up after itself either way.
#
# Exit code 0 = PASS. Run it monthly; a backup nobody restored is a hope.
#
set -euo pipefail

ENV_FILE=${ENV_FILE:-/etc/restic/env}
WORK=$(mktemp -d /var/tmp/restore-test.XXXXXX)
PREFIX="rt-$$"
FAILED=0

log() { printf '\n==> %s\n' "$*"; }
ok() { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
bad() {
  printf '  \033[1;31mFAIL\033[0m %s\n' "$*"
  FAILED=1
}
die() {
  printf '!! %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "${PREFIX}-coolify" "${PREFIX}-affine" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -r "$ENV_FILE" ] || die "missing $ENV_FILE"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

wait_pg() {
  local c=$1 i
  for i in $(seq 1 40); do
    docker exec "$c" pg_isready -U postgres -q >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# --- pull the latest snapshot -------------------------------------------------
log "restoring latest snapshot to $WORK"
restic restore latest --target "$WORK"
SRC="$WORK/var/backups/homelab"
for f in coolify-db.dump affine-postgres.dump pocketbase-data.db; do
  [ -s "$SRC/$f" ] || die "missing $f in snapshot"
done

# --- coolify database ---------------------------------------------------------
log "coolify-db"
docker run -d --name "${PREFIX}-coolify" -e POSTGRES_PASSWORD=test \
  postgres:15-alpine >/dev/null
wait_pg "${PREFIX}-coolify" || die "scratch coolify postgres never became ready"
docker exec -i "${PREFIX}-coolify" pg_restore -U postgres -d postgres \
  --create --no-owner <"$SRC/coolify-db.dump" 2>"$WORK/coolify.err" || true

coolify_tables=$(docker exec "${PREFIX}-coolify" psql -U postgres -d coolify -tAc \
  "select count(*) from information_schema.tables where table_schema='public';")
coolify_live=$(docker exec coolify-db sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from information_schema.tables where table_schema='"'"'public'"'"';"')
coolify_svcs=$(docker exec "${PREFIX}-coolify" psql -U postgres -d coolify -tAc \
  "select count(*) from services;")

if [ "${coolify_tables:-0}" -ge 80 ]; then
  ok "coolify: ${coolify_tables} tables (live: ${coolify_live}), ${coolify_svcs} services"
else
  bad "coolify: only ${coolify_tables} tables restored"
  sed -n '1,5p' "$WORK/coolify.err" | sed 's/^/     /'
fi

# --- affine database ----------------------------------------------------------
log "affine postgres"
docker run -d --name "${PREFIX}-affine" -e POSTGRES_PASSWORD=test \
  pgvector/pgvector:pg16 >/dev/null
wait_pg "${PREFIX}-affine" || die "scratch affine postgres never became ready"
docker exec -i "${PREFIX}-affine" pg_restore -U postgres -d postgres \
  --create --no-owner <"$SRC/affine-postgres.dump" 2>"$WORK/affine.err" || true

affine_db=$(pg_restore -l "$SRC/affine-postgres.dump" 2>/dev/null |
  sed -n 's/^; *dbname: //p' | head -1)
affine_db=${affine_db:-affine}
affine_tables=$(docker exec "${PREFIX}-affine" psql -U postgres -d "$affine_db" -tAc \
  "select count(*) from information_schema.tables where table_schema='public';")
affine_migrations=$(docker exec "${PREFIX}-affine" psql -U postgres -d "$affine_db" -tAc \
  "select count(*) from _prisma_migrations;")

if [ "${affine_tables:-0}" -ge 50 ] && [ "${affine_migrations:-0}" -gt 0 ]; then
  ok "affine: ${affine_tables} tables, ${affine_migrations} prisma migrations"
else
  bad "affine: ${affine_tables} tables, ${affine_migrations} prisma migrations"
  sed -n '1,5p' "$WORK/affine.err" | sed 's/^/     /'
fi

# --- pocketbase ---------------------------------------------------------------
log "pocketbase sqlite"
integrity=$(sqlite3 "$SRC/pocketbase-data.db" 'PRAGMA integrity_check;' 2>&1)
pb_tables=$(sqlite3 "$SRC/pocketbase-data.db" \
  "select count(*) from sqlite_master where type='table';" 2>/dev/null || echo 0)
if [ "$integrity" = "ok" ] && [ "${pb_tables:-0}" -gt 0 ]; then
  ok "pocketbase: integrity ok, ${pb_tables} tables"
else
  bad "pocketbase: integrity=${integrity}, ${pb_tables} tables"
fi

# --- summary ------------------------------------------------------------------
if [ "$FAILED" -eq 0 ]; then
  log "PASS — snapshot restored and verified"
else
  log "FAIL — see above"
fi
exit "$FAILED"
