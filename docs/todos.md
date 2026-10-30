# Server TODOs

Ordered by risk × effort, not by effort alone. Each item says what "done" looks
like, so it can actually be checked off. Context lives in `docs/server.md`.

## P0 — Exposure and access

### 1. Key-only SSH, one key per device

Passwords were accepted until 2026-10-29 (`Accepted password for matias from
192.168.2.1`). Each device now gets its own key, so they can be revoked
independently.

**Status: done 2026-10-29.** `matias@Matias-Mac-mini.local-homelab` installed,
`PasswordAuthentication no` + `AuthenticationMethods publickey` live. Server
now advertises `publickey` only.

**Done when:** `ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no <host> true`
prints `ok` from every machine you use, and `PasswordAuthentication no` is in
`/etc/ssh/sshd_config.d/99-hardening.conf`.

### 2. Firewall: deny inbound, LAN only

**Status: done 2026-10-29.** `ufw` active, `deny (incoming)`, 22/80/443
allowed from `192.168.0.0/16`. Tunnel logins still work (loopback).

**Done when:** `sudo ufw status verbose` shows `deny (incoming)`, and 22/80/443
are allowed from `192.168.0.0/16` only. A tunnel login still works.

### 3. Close Docker-published ports

`8000`, `8080`, `6001-6002` are on `0.0.0.0` via Docker's own iptables chain,
which `ufw` cannot filter. Either bind them to `127.0.0.1` in the compose files
or add `DOCKER-USER` rules.

**Done when:** `docker ps` shows no `0.0.0.0:` bindings except 80/443, and
Coolify's UI still loads through the tunnel.

### 4. Confirm the router forwards nothing

**Done when:** a port scan of the WAN IP shows 22/80/443/8000/8080 closed.
This is a manual check on the router; nothing on the box can prove it.

## P1 — Recovery

### 5. Off-box, automated backups

See "What gets backed up" below.

**Done when:** a `systemd` timer runs nightly, the repo has an off-box copy
(another disk **and** an offsite target), and `restic snapshots` shows at least
two successful runs. Encryption is on; nothing readable is stored off-box.

### 6. Test the restore

**Done when:** a dump from last night is restored into a scratch container and
you can open a real Affine document and log into Coolify from it. Until this
passes, item 5 is unproven.

## P2 — Visibility

### 7. Alerts to your phone

Coolify's notification rows (Telegram/Discord/Slack/email) all exist and are
all disabled. At minimum: deployment failure, backup failure, disk usage,
server unreachable.

**Done when:** stopping a test container produces a message you actually see.

## P3 — Decisions, not tasks

### 8. Disk encryption (LUKS)

A stolen laptop means a stolen server: Postgres data, Coolify secrets, the
tunnel token. Realistically this is a reinstall. Decide, don't drift.

### 9. The `docker` group

**Status: done 2026-10-30.** `matias` removed from `docker` (root-equivalent)
and the unused `lxd` group. `sudoers/docker-readonly` grants passwordless
`ps/images/stats/volume ls/network ls/system df/info` only — `inspect` and
`logs` stay password-gated, since Coolify's `APP_KEY` plus its web terminal is
effectively root.

## Accepted risks

- **Root SSH via publickey** — Coolify's web terminal needs it; that's why the
  config uses `prohibit-password`, not `no`.
- **80/443 reachable from the internet** — Let's Encrypt renews over HTTP-01.
  Only revisitable by moving to DNS-01.
- **LAN trust** — anything on the home network can reach 22/80/443.

## What gets backed up

| Source | What it is | Why it matters |
|---|---|---|
| `coolify-db` (volume) | Coolify's Postgres: apps, services, users, settings, encrypted env vars | Lose it and the panel forgets your whole setup |
| `/data/coolify` | compose files, `.env` secrets, proxy config, `acme.json` | Rebuilding by hand is hours of guesswork |
| `..._affine-postgres-data` | Affine's Postgres (documents, blob metadata) | This *is* your notes |
| `..._affine-storage` | Affine file storage | Attachments |
| `..._pocketbase-data` | PocketBase SQLite DB + uploads | The app's data |
| `..._pocketbase-hooks` | PocketBase JS hooks | Small, but hand-written |
| `/etc/cloudflared/token` | Tunnel credential | Regenerable, but painful |

Total volume size today: **~160 MB** — small enough that there is no excuse.

**Not a backup:** a snapshot on the same disk, or `cp` of a live Postgres
directory (inconsistent). Use `pg_dump` for Postgres, `.backup` for SQLite.
