# starisk nightly (containerised)

Runs the [starisk](https://github.com/MatiasAgelvis/starisk) crawl once a night
in a **one-shot container**, because the plan is a clone in a container on a
schedule, and this box has the residential IP Coursera wants.

**Division of labour** (the repo's own contract, from `nightly.py`): the repo
owns the decisions — queue → smoke → crawl → derive → gate → commit → PR, with
exit codes. The box owns only three things: the runtime, the schedule, the
alerts.

| File | Lines | What it is |
|---|---|---|
| `Dockerfile` | ~18 | `node:24-slim` + python3 + git |
| `entrypoint.sh` | ~18 | clone on first run, checkout `develop`, exec the runner |
| `docker-compose.yml` | ~18 | one service, two mounts |
| `systemd/starisk-nightly.{service,timer}` | ~20 | schedule + exit-code policy |

There is no wrapper script: the unit calls `docker compose run` directly, and
`homelab-health-check` turns the runner's `logs/last-run.json` into ntfy alerts.

## Runtime shape

| | |
|---|---|
| Container | `starisk-nightly:latest`, `--rm`, no ports |
| Volume | `starisk-workspace` → `/workspace` (clone + `pipeline/data/.cache/pages`) |
| Bind | `~/.local/state/starisk` → `/workspace/logs` (health check reads it) |
| Env | `/home/matias/.config/starisk/env` (mode 600) |
| Schedule | 04:00, `Persistent=true`, `SuccessExitStatus=0 10` |

The cache matters: without the volume every night re-downloads pages it already
has, and `--offline` re-scoring would have nothing to read.

## Alerts

The unit's exit code decides "failed"; the health check reads the record:

| Code | Meaning | Result |
|---|---|---|
| 0 | committed | unit success; health check passes |
| 10 | nothing changed | unit success; health check passes |
| 20 | gate refused | unit failed → ntfy high |
| 30 | partial (rate limited) | unit failed → ntfy high |
| 40/50/60/70 | git / smoke / config / failure | unit failed → ntfy high |

Freshness also matters: if `last-run.json` is older than 36 h, the health check
alerts even when the unit last succeeded — that catches a disabled timer.

## Setup

**1. Secrets** — `/home/matias/.config/starisk/env`, mode 600:

```sh
TURSO_DATABASE_URL=libsql://<db>-<org>.turso.io
TURSO_AUTH_TOKEN=<token>
GITHUB_TOKEN=github_pat_...   # Contents: write, Pull requests: write
NTFY_TOPIC=<topic>
```

`NTFY_TOPIC` is only used by `homelab-health-check`, not by the container.

**2. Build and install**

```sh
sudo docker compose -f ~/dotfiles/server/starisk/docker-compose.yml build nightly
sudo install -m 0644 ~/dotfiles/systemd/starisk-nightly.service \
  ~/dotfiles/systemd/starisk-nightly.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

**3. Test with systemd itself** (no wrapper to drift):

```sh
sudo systemctl start starisk-nightly.service
journalctl -u starisk-nightly -n 60 --no-pager
```

For a smaller, quieter rehearsal, run the container by hand:

```sh
sudo docker compose -f ~/dotfiles/server/starisk/docker-compose.yml run --rm nightly --dry-run
sudo docker compose -f ~/dotfiles/server/starisk/docker-compose.yml run --rm nightly --limit 5
```

**4. Schedule**

```sh
sudo systemctl enable --now starisk-nightly.timer
systemctl list-timers starisk-nightly.timer
```

## Notes

- The container runs as root (Docker socket on the host). No ports, and the only
  host mount is the log directory.
- Python inside is Debian's 3.11, which satisfies `requires-python >= 3.10`. If
  the code starts using 3.12+ features, base the image on `python:3.13-slim` and
  copy the node binary from `node:24-slim`.
- The host clone in `~/src/starisk` is development only; the job uses the copy
  inside the volume.
- The deploy key generated earlier is unused (the runner pushes with
  `GITHUB_TOKEN`); revoke it when convenient.
