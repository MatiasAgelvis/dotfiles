# starisk nightly (containerised)

Runs the [starisk](https://github.com/MatiasAgelvis/starisk) crawl once a night
in a **one-shot container**, because the repo's plan is a clone in a container
on a schedule, and the box has the residential IP Coursera wants.

The decisions live in the repo — `pipeline/starisk/nightly.py` owns queue →
smoke → crawl → derive → gate → commit → PR. This directory owns the image,
the volume and the alerting:

```
server/starisk/
├── Dockerfile              # node:24-slim + python3 + git
├── entrypoint.sh           # clone on first run, then `python3 -m starisk.nightly`
├── docker-compose.yml      # one service, two mounts
└── nightly.sh              # host wrapper: run container, map exit code → ntfy
systemd/starisk-nightly.{service,timer}
```

## Runtime shape

| | |
|---|---|
| Container | `starisk-nightly:latest`, `--rm`, no ports, root inside |
| Volume | `starisk-workspace` → `/workspace` (clone + `pipeline/data/.cache/pages`) |
| Bind | `~/.local/state/starisk` → `/workspace/logs` (health check reads it) |
| Env | `/home/matias/.config/starisk/env` (mode 600) |
| Schedule | 04:00, `Persistent=true`, `SuccessExitStatus=0 10` |

The cache matters: without the volume every night re-downloads pages it already
has, and `--offline` re-scoring would have nothing to read.

## What one run does (per the repo)

1. read the Turso request queue into `sources.json`
2. smoke-check that Coursera still parses and the deployed data is served
3. crawl (default budget 60 courses, oldest first), localise logos, rebuild the
   program index, copy data into `web/`
4. gate: lost records, a score drop, new errors or stray code changes become a
   **notification**, not a commit
5. commit as `Starisk Bot` on `data/crawl`, push, keep one PR open against
   `develop`

`main` is never touched. Publishing is a human merge.

## Exit codes → alerts

| Code | Meaning | Wrapper |
|---|---|---|
| 0 | committed | ntfy default, with commit + PR link |
| 10 | nothing changed | silent (health check watches freshness) |
| 20 | gate refused | ntfy high |
| 30 | partial (rate limited) | ntfy default |
| 40/50/60/70 | git / smoke / config / failure | ntfy high |

## Setup

**1. Secrets** — `/home/matias/.config/starisk/env`, mode 600:

```sh
TURSO_DATABASE_URL=libsql://<db>-<org>.turso.io
TURSO_AUTH_TOKEN=<token>
GITHUB_TOKEN=github_pat_...   # Contents: write, Pull requests: write
NTFY_TOPIC=<topic>
```

Mint the Turso token with `turso db tokens create <db>` (Vercel's *Sensitive*
variables come through as `{SENSITIVE}`).

**2. Build and install**

```sh
sudo docker compose -f ~/dotfiles/server/starisk/docker-compose.yml build nightly
sudo install -m 0755 ~/dotfiles/server/starisk/nightly.sh /usr/local/bin/starisk-nightly
sudo install -m 0644 ~/dotfiles/systemd/starisk-nightly.service \
  ~/dotfiles/systemd/starisk-nightly.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

**3. Test**

```sh
~/dotfiles/server/starisk/nightly.sh --dry-run     # config, connectivity, smoke
~/dotfiles/server/starisk/nightly.sh --limit 5     # small real run + push + PR
```

The first `--dry-run` also clones the repo into the volume, so expect it to take
a little longer than later runs.

**4. Schedule**

```sh
sudo systemctl enable --now starisk-nightly.timer
systemctl list-timers starisk-nightly.timer
```

## Notes

- The container runs as root (Docker socket on the host). It has no ports and no
  host mounts beyond the log directory, so the blast radius is its volume.
- Python inside is Debian's 3.11, which satisfies the repo's
  `requires-python >= 3.10`. If the code starts using 3.12+ features, switch the
  base to `python:3.13-slim` and copy the node binary from `node:24-slim`.
- The host clone in `~/src/starisk` is only for development; the job uses the
  copy inside the volume.
- The deploy key generated earlier is unused (the runner pushes with
  `GITHUB_TOKEN`); revoke it when convenient.
