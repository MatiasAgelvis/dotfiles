# starisk nightly

Runs the [starisk](https://github.com/MatiasAgelvis/starisk) crawl once a night
from this box, because it has the residential IP Coursera wants and a
notification channel the repo cannot own. Then it commits the updated data and
pushes, so the static site rebuilds on its host.

```
server/starisk/nightly.sh            # the run
systemd/starisk-nightly.{service,timer}   # 04:00, Persistent=true
```

## What one run does

1. `git fetch`, hard-reset to `origin/main`, and rebuild the bot branch
   `nightly` (this clone is bot-owned — don't edit it by hand)
2. `python -m starisk.demand --write` — verifies new requests against Coursera
   and merges them into `data/requests.json`
3. the `pipeline:crawl` chain — `crawl --max-age 7`, logos, hi-res logos,
   `groupings --write`
4. `node web/scripts/sync-data.mjs` — copies the data into `web/`
5. refuse to publish if a tracked data file was **deleted** (a parse bug that
   empties `scores.json` must not reach a branch)
6. if anything changed: commit as the bot, force-push `nightly`, and open (or
   refresh) a pull request against `main`
7. write `~/.local/state/starisk/last-run` (checked by `homelab-health-check`)
8. `ntfy` digest: commit summary + compare link, "no changes", or a
   high-priority failure

`main` is never written by the job. Merging the PR publishes production, and the
branch gets a Vercel preview in the meantime.

`name/*` rows are never automated — they need a human to resolve a slug.

## Setup

**1. Deploy key** — add this to the repo as a deploy key *with write access*:

```sh
cat ~/.ssh/id_ed25519_starisk.pub
```

**2. Secrets** — never in the repo:

```sh
install -d -m 700 ~/.config/starisk
cat > ~/.config/starisk/env <<'EOF'
TURSO_DATABASE_URL=libsql://<db>-<org>.turso.io
TURSO_AUTH_TOKEN=<token>
NTFY_TOPIC=<topic>
# Optional: a bot PAT with repo scope, so the job can open the PR itself.
# GH_TOKEN=github_pat_...
EOF
chmod 600 ~/.config/starisk/env
```

Mint the Turso token with `turso db tokens create <db>` rather than pulling
Vercel's *Sensitive* variable, which comes through as `{SENSITIVE}`.

Commits are authored as `starisk-bot <starisk-bot@users.noreply.github.com>`.
Override with `STARISK_BOT_NAME` / `STARISK_BOT_EMAIL` in the env file. The push
uses the repo-scoped deploy key, not your account; `GH_TOKEN` is only needed for
automatic pull-request creation.

**3. Install**

```sh
cd ~/src/starisk && mise trust && mise install
sudo install -m 0755 ~/dotfiles/server/starisk/nightly.sh /usr/local/bin/starisk-nightly
sudo install -m 0644 ~/dotfiles/systemd/starisk-nightly.service \
  ~/dotfiles/systemd/starisk-nightly.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

**4. Test before scheduling** — a small, polite run:

```sh
~/dotfiles/server/starisk/nightly.sh --dry-run          # no writes, no push
STARISK_LIMIT=5 ~/dotfiles/server/starisk/nightly.sh    # 5 courses, real
```

**5. Schedule**

```sh
sudo systemctl enable --now starisk-nightly.timer
systemctl list-timers starisk-nightly.timer
```

## Cadence and courtesy

The default `--max-age 7` means each course is refetched weekly: 971 sources ÷ 7
≈ **140 courses/night**, two requests each, 1.5 s apart — roughly 5–10 minutes.
The first run after enabling is the heaviest, because records older than seven
days all qualify. `STARISK_LIMIT` caps a single night if you want to spread it.

Coursera returning **403/429** is the signal to back off: the run exits non-zero
and you get a high-priority alert. Do not raise the delay down or parallelise it;
the repo's whole design is "one polite residential crawler".

## Failure modes worth knowing

- **Silent zero rows**: the script fails on a non-zero exit, but a site change
  that parses to zero reviews does not. `scores.json` shrinks in the commit
  diff — review the push if you notice a sudden drop.
- **Dead cron**: `homelab-health-check` alerts when `last-run` is older than
  36 h, so a disabled timer or a wedged job is visible.
- **Diverged clone**: the script refuses to merge. Fix with
  `git -C ~/src/starisk pull --rebase`.
