# Backups

Nightly, automated, off-box, encrypted. Target: **Cloudflare R2** via restic.
Script: `scripts/backup.sh`; units: `systemd/homelab-backup.{service,timer}`.

## What gets backed up

| Staged file | Source | Method |
|---|---|---|
| `coolify-db.dump` | `coolify-db` container | `pg_dump -Fc` |
| `affine-postgres.dump` | Affine's Postgres | `pg_dump -Fc` |
| `pocketbase-*.db` | PocketBase volume | `sqlite3 .backup` (WAL-safe) |
| `pocketbase-files.tar.gz` | PocketBase volume, minus DBs | tar |
| `coolify-data.tar.gz` | `/data/coolify` | tar |
| `affine-storage.tar.gz` | Affine storage volume | tar |

Snapshot paths are `/var/backups/homelab/...`, so restores are predictable.
Retention: 7 daily, 4 weekly, 6 monthly.

## One-time setup

### 1. R2 bucket and token

Cloudflare dashboard → R2:

1. Create bucket, e.g. `homelab-backups`.
2. **Manage R2 API Tokens** → create token with **Object Read & Write**,
   scoped to that bucket only.
3. Note the **Access Key ID**, **Secret Access Key**, and your **Account ID**
   (the endpoint is `https://<account-id>.r2.cloudflarestorage.com`).

### 2. Credentials

```sh
sudo install -d -m 700 /etc/restic
sudo tee /etc/restic/env >/dev/null <<'EOF'
RESTIC_REPOSITORY=s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/homelab-backups
RESTIC_PASSWORD=<long random passphrase>
AWS_ACCESS_KEY_ID=<access key id>
AWS_SECRET_ACCESS_KEY=<secret access key>
AWS_DEFAULT_REGION=auto
EOF
sudo chown root:root /etc/restic/env
sudo chmod 600 /etc/restic/env
```

**Store `RESTIC_PASSWORD` in your password manager now.** Without it the
repository is unreadable — there is no recovery.

### 3. Install

```sh
sudo ./scripts/install-backup.sh --run
```

That installs `restic`/`sqlite3`, copies the script to `/usr/local/bin/homelab-backup`,
installs the units, enables the timer, and takes a first backup. Safe to re-run
after editing anything — it's the upgrade path too. If `/etc/restic/env` is
missing or incomplete, it installs the files but leaves the timer **disabled**
and says why.

### 4. First run

```sh
sudo /usr/local/bin/homelab-backup     # creates the repo, uploads, prunes
sudo journalctl -u homelab-backup -n 50 --no-pager
restic snapshots                       # with the env file sourced
systemctl list-timers homelab-backup.timer
```

## Restore

### List and inspect

```sh
set -a; . /etc/restic/env; set +a
restic snapshots
restic ls latest
```

### Extract files

```sh
restic restore latest --target /tmp/restore \
  --include /var/backups/homelab/coolify-data.tar.gz
```

### Postgres (into a scratch container, never over the live one)

```sh
restic restore latest --target /tmp/restore --include /var/backups/homelab/coolify-db.dump

docker run -d --name pg-restore-test -e POSTGRES_PASSWORD=test \
  -p 127.0.0.1:55432:5432 postgres:15-alpine
sleep 5
docker exec -i pg-restore-test pg_restore -U postgres -d postgres --create \
  < /tmp/restore/var/backups/homelab/coolify-db.dump
docker exec pg-restore-test psql -U postgres -d coolify -c '\dt'
```

### PocketBase

```sh
restic restore latest --target /tmp/restore --include /var/backups/homelab/pocketbase-data.db
sqlite3 /tmp/restore/var/backups/homelab/pocketbase-data.db 'PRAGMA integrity_check;'
sqlite3 /tmp/restore/var/backups/homelab/pocketbase-data.db '.tables'
```

## The test that makes it real

```sh
sudo ./scripts/restore-test.sh
```

Restores the newest snapshot into throwaway containers (no ports published, live
services untouched), checks the Coolify and Affine schemas plus PocketBase
integrity, prints `PASS`/`FAIL`, and cleans up. Non-zero exit on failure, so it
can be put on a monthly timer later.

Once a month is enough. Until it passes, these are files, not backups.
Tracked as #6 in `docs/todos.md`.

## Notes

- `restic check --read-data-subset=1%` monthly catches bit rot cheaply.
- The script refuses to run as a non-root user: it reads Docker and
  `/data/coolify`.
- `RESTIC_PASSWORD` and the R2 keys are the only secrets; they live in
  `/etc/restic/env`, never in this repo.
