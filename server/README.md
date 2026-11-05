# server

Docker stacks, as plain text. No panel, no database holding the config — these
files are the source of truth, and `git` is the deploy history.

```
server/
├── deploy.sh              # sudo ./server/deploy.sh <stack> [up|down|logs|ps|restart]
├── teardown-coolify.sh    # one-time: removes Coolify, rescues the origin cert
└── traefik/
    ├── docker-compose.yml
    ├── dynamic/
    │   ├── tls.yaml       # default wildcard certificate
    │   └── routes.yaml    # one router+service block per app
    └── certs/             # origin.pem / origin.key — gitignored
```

## Why not Coolify

Coolify's config lived in its own Postgres, so the panel *was* the source of
truth, and it idled at ~810 MB with a queue worker in the deploy path. Here the
config is the file; Traefik reads `dynamic/` and reloads on save.

## Traffic path

```
browser → Cloudflare (TLS, Access, wildcard) → tunnel → Traefik :443 → container
```

Cloudflare terminates TLS, so Traefik serves the Cloudflare Origin certificate
as its default certificate and never does ACME. That is why every
`*.matiasagelvis.com` hostname works without per-host issuance.

## Adding an app

1. `server/<app>/docker-compose.yml`
   ```yaml
   services:
     app:
       image: something:tag
       restart: unless-stopped
       networks: [traefik]

   networks:
     traefik:
       external: true
   ```
2. A route in `server/traefik/dynamic/routes.yaml`:
   ```yaml
   http:
     routers:
       app:
         rule: Host(`app.matiasagelvis.com`)
         entryPoints: [https]
         tls: {}
         service: app
     services:
       app:
         loadBalancer:
           servers:
             - url: http://app:8080
   ```
3. `sudo ~/dotfiles/server/deploy.sh traefik` (reload is automatic, this just
   verifies) and `sudo ~/dotfiles/server/deploy.sh <app>`

No Docker socket is mounted into Traefik, so a compromised proxy cannot drive
Docker. The cost is that adding an app means two files instead of labels.

## Day-to-day

| Task | Command |
|---|---|
| Update images | `sudo ~/dotfiles/server/deploy.sh traefik` |
| Logs | `sudo ~/dotfiles/server/deploy.sh traefik logs` |
| Status | `sudo docker compose -f ~/dotfiles/server/traefik/docker-compose.yml ps` |
| Validate config | `sudo docker compose -f ~/dotfiles/server/traefik/docker-compose.yml config` |

## Rollback

- Config change: `git revert` / edit the file back — Traefik hot-reloads.
- Bad image: pin the previous tag in the compose file and redeploy.
- Before the Coolify wipe: the nightly restic snapshot is the only rollback, so
  the teardown script refuses to run without the origin cert present.
