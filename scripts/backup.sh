#!/usr/bin/env bash
#
# scripts/backup.sh — nightly off-box backup of the homelab services.
#
# Run as root (normally via homelab-backup.timer):
#
#     sudo ./scripts/backup.sh
#
# Needs /etc/restic/env, mode 600, owned by root:
#
#     RESTIC_REPOSITORY=s3:https://<account>.r2.cloudflarestorage.com/homelab-backups
#     RESTIC_PASSWORD=<long random passphrase>   # keep a copy in your password manager
#     AWS_ACCESS_KEY_ID=...
#     AWS_SECRET_ACCESS_KEY=...
#     AWS_DEFAULT_REGION=auto
#
# Secrets never live in this repo. Containers are resolved by compose label so
# the random suffixes Coolify generates don't matter.
#
set -euo pipefail

ENV_FILE=${ENV_FILE:-/etc/restic/env}
STAGE=${STAGE:-/var/backups/homelab}

log() { printf '%s %s\n' "$(date -Is)" "$*"; }
die() {
  log "ERROR: $*"
  exit 1
}

[ "$(id -u)" -eq 0 ] || die "run as root: it reads Docker and /data/coolify"
[ -r "$ENV_FILE" ] || die "missing $ENV_FILE"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

command -v restic >/dev/null || die "restic is not installed"
command -v sqlite3 >/dev/null || die "sqlite3 is not installed"
for v in RESTIC_REPOSITORY RESTIC_PASSWORD; do
  [ -n "${!v:-}" ] || die "$v is empty in $ENV_FILE"
done

# Stable staging path: restic snapshots then have predictable paths to restore.
# Locked down because the tarballs contain secrets (Coolify .env, DB hashes).
mkdir -p "$STAGE"
chmod 700 "$STAGE"
find "$STAGE" -mindepth 1 -delete

# --- resolve containers ------------------------------------------------------
# `postgres` exists twice (Coolify's own DB and Affine's), so exclude Coolify's.
affine_pg=$(docker ps --filter 'label=com.docker.compose.service=postgres' \
  --format '{{.Names}}' | grep -vx 'coolify-db' | head -1 || true)
affine=$(docker ps --filter 'label=com.docker.compose.service=affine' \
  --format '{{.Names}}' | head -1 || true)
pocketbase=$(docker ps --filter 'label=com.docker.compose.service=pocketbase' \
  --format '{{.Names}}' | head -1 || true)

# --- postgres ----------------------------------------------------------------
dump_pg() {
  local container=$1 out=$2
  log "pg_dump $container"
  docker exec "$container" sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' >"$out" ||
    die "pg_dump failed for $container"
}

dump_pg coolify-db "$STAGE/coolify-db.dump"
if [ -n "$affine_pg" ]; then
  dump_pg "$affine_pg" "$STAGE/affine-postgres.dump"
else
  log "WARNING: no affine postgres container found, skipping"
fi

# --- pocketbase (SQLite: use .backup, never copy a live db) ------------------
if [ -n "$pocketbase" ]; then
  pb_data=$(docker inspect "$pocketbase" \
    --format '{{range .Mounts}}{{if eq .Destination "/app/pb_data"}}{{.Source}}{{end}}{{end}}')
  log "sqlite .backup $pocketbase ($pb_data)"
  for db in data.db auxiliary.db logs.db; do
    [ -f "$pb_data/$db" ] || continue
    sqlite3 "$pb_data/$db" ".backup '$STAGE/pocketbase-$db'"
  done
  # Uploads and any non-database files.
  tar -czf "$STAGE/pocketbase-files.tar.gz" -C "$pb_data" \
    --exclude='*.db' --exclude='*.db-wal' --exclude='*.db-shm' .
else
  log "WARNING: no pocketbase container found, skipping"
fi

# --- file trees --------------------------------------------------------------
log "tar /data/coolify"
tar -czf "$STAGE/coolify-data.tar.gz" -C /data coolify

if [ -n "$affine" ]; then
  storage=$(docker inspect "$affine" \
    --format '{{range .Mounts}}{{if eq .Destination "/root/.affine/storage"}}{{.Source}}{{end}}{{end}}')
  if [ -n "$storage" ] && [ -d "$storage" ]; then
    log "tar affine storage"
    tar -czf "$STAGE/affine-storage.tar.gz" -C "$storage" .
  fi
fi

log "staged $(du -sh "$STAGE" | cut -f1)"
chmod -R go-rwx "$STAGE"

# --- restic ------------------------------------------------------------------
export RESTIC_HOST=${RESTIC_HOST:-$(hostname)}

if ! restic snapshots >/dev/null 2>&1; then
  log "initialising restic repository"
  restic init
fi

log "uploading"
restic backup "$STAGE" --tag homelab

log "pruning (7 daily / 4 weekly / 6 monthly)"
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

log "done"
