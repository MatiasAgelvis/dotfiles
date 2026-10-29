# ubuntu — server notes

Inventory of the machine these dotfiles run on. Facts here are dated; re-verify
rather than trust them.

## Host

| | |
|---|---|
| Hostname | `ubuntu` |
| OS | Ubuntu 26.04.1 LTS (kernel 7.0.0-38) |
| CPU/RAM | 15 GiB RAM, 4 GiB swap |
| Disk | `/dev/sda3`, 641 GB (`/`) |
| Networks | `enp1s0f0` 192.168.2.3, `wlp2s0b1` 192.168.1.96 |
| Role | laptop repurposed as a home server, lid closed |

## Access

- SSH on `:22` (key auth; `authorized_keys` present).
- Everything public goes through a **Cloudflare Tunnel** (`cloudflared.service`,
  token in `/etc/cloudflared/token`) with **Zero Trust** in front. No ports are
  forwarded on the router.

## Services (Coolify-managed)

Coolify 4.5.0 at `coolify.matiasagelvis.com`, with the Traefik v3.7 proxy on
`80/443`. Sign-up is disabled.

| Service | URL | Notes |
|---|---|---|
| Coolify | `coolify.matiasagelvis.com` | panel + realtime + terminal ws |
| Affine | `affine.matiasagelvis.com` | own `pgvector` Postgres + Redis |
| PocketBase | `pocketbase.matiasagelvis.com` | |

Coolify projects: `pocketbase test`, `docs` (nothing deployed). Leftover
Let's Encrypt certs exist for `docs.*`, `api.docs.*`, `docs-fs.*`,
`files.docs.*` — dead entries from an earlier deployment.

## Known gaps (not yet addressed)

1. Coolify's container publishes `:8000` on `0.0.0.0`, bypassing Traefik/TLS.
   Traefik's dashboard also publishes `:8080`. Docker's own iptables chain means
   `ufw` does not filter either (see `docs/todos.md` #3).
2. No verified backup job for the Affine Postgres or PocketBase data.
3. `matias` is in the `docker` group (root-equivalent).

Resolved 2026-10-29: `ufw` enabled (deny inbound, LAN-only 22/80/443) and SSH is
key-only (`docs/todos.md` #1, #2).

## Tooling

System packages come from apt (`packages/apt-ubuntu.txt`); interactive CLI
tools come from mise (`mise/config.toml`). Two consequences:

- `sudo <tool>` and systemd units do **not** see mise's binaries. If a tool is
  ever needed by root or a service, install it via apt and adjust PATH order.
- `mise upgrade` is the only path to security patches for those tools — apt's
  unattended-upgrades does not cover them.

## Rebuild order

1. Base OS install, static IP on the LAN.
2. `cloudflared` tunnel + Zero Trust policy (not reproducible from this repo —
   it lives in Cloudflare's dashboard).
3. Docker + Coolify, then the services above.
4. `git clone https://github.com/MatiasAgelvis/dotfiles ~/dotfiles`
5. `~/dotfiles/bootstrap/linux.sh --chsh`
6. See the "Known gaps" list before exposing anything new.
