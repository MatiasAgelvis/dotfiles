# starisk nightly

Runs the [starisk](https://github.com/MatiasAgelvis/starisk) crawl once a night
on bare metal. The box has the residential IP Coursera wants and the
notification channel the repo cannot own.

**All the logic is in the repo.** `pipeline/starisk/nightly.py` owns queue →
smoke → crawl → derive → gate → commit → PR, and its exit codes are the
interface to the timer. This directory is only a systemd unit:

```
systemd/starisk-nightly.service   # runs `python -m starisk.nightly`
systemd/starisk-nightly.timer     # 04:00, Persistent=true
```

No wrapper script, no container, no duplicated orchestration.

## Runtime shape

| | |
|---|---|
| Clone | `/home/matias/src/starisk` (bot-owned; the runner switches branches) |
| Toolchain | mise shims — python 3.13 / node 24 from the repo's `mise.toml` |
| Secrets | `/home/matias/src/starisk/.env.prod` (`.env*` is gitignored) |
| Schedule | 04:00, `Persistent=true`, `SuccessExitStatus=0 10` |
| State | `logs/last-run.json`, `pipeline/data/.cache/pages` |

The runner's `prepare()` refuses to start on a dirty tree, and gitignored files
are invisible to it — which is why `.env.prod` can live in the clone without
breaking anything.

## Alerts

The unit's exit code decides "failed"; `homelab-health-check` reads the record
for the reason and for freshness:

| Code | Meaning | Result |
|---|---|---|
| 0 | committed | success |
| 10 | nothing changed | success |
| 20 | gate refused | unit failed → ntfy high |
| 30 | partial (rate limited) | unit failed → ntfy high |
| 40/50/60/70 | git / smoke / config / failure | unit failed → ntfy high |

If `logs/last-run.json` is older than 36 h, the health check alerts even when
the last run succeeded — that catches a disabled timer.

## Setup

**1. Secrets** — `/home/matias/src/starisk/.env.prod`, mode 600:

```sh
TURSO_DATABASE_URL=libsql://<db>-<org>.turso.io
TURSO_AUTH_TOKEN=<token>
GITHUB_TOKEN=github_pat_...   # Contents: write, Pull requests: write
```

Mint the Turso token with `turso db tokens create <db>` (Vercel's *Sensitive*
variables come through as `{SENSITIVE}`). `NTFY_TOPIC` is not needed here — the
digest goes through `homelab-health-check`, which reads its own env file.

**2. Install**

```sh
cd ~/src/starisk && mise trust && mise install
sudo install -m 0644 ~/dotfiles/systemd/starisk-nightly.service \
  ~/dotfiles/systemd/starisk-nightly.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/starisk-nightly   # stale from the wrapper version
```

**3. Test through systemd**

```sh
sudo systemctl start starisk-nightly.service
journalctl -u starisk-nightly -n 60 --no-pager
```

For a smaller rehearsal, run the same command the unit runs:

```sh
cd ~/src/starisk/pipeline && set -a && . ../.env.prod && set +a
python -m starisk.nightly --dry-run
python -m starisk.nightly --limit 5
```

**4. Schedule**

```sh
sudo systemctl enable --now starisk-nightly.timer
systemctl list-timers starisk-nightly.timer
```

## Notes

- The clone is bot-owned: the runner resets/rebases branches. Don't edit files
  there by hand; work on your own machine.
- Commits are authored as `Starisk Bot <bot@matiasagelvis.com>` (override with
  `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` in `.env.prod`).
- The deploy key generated earlier is unused (the runner pushes with
  `GITHUB_TOKEN`); revoke it when convenient.
