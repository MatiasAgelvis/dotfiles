#!/usr/bin/env bash
#
# scripts/install-origin-cert.sh — install a wildcard origin certificate as
# Traefik's default certificate.
#
#     sudo ./scripts/install-origin-cert.sh origin.pem origin.key
#
# Get the pair from Cloudflare → SSL/TLS → Origin Server → Create Certificate,
# covering `*.example.com` and `example.com` (15 years). The cert is free and
# only trusted by Cloudflare — which is exactly the point: cloudflared connects
# to https://localhost:443 with "No TLS Verify", and Cloudflare (Full strict)
# trusts this cert on the edge→origin leg.
#
set -euo pipefail

CERT=${1:-}
KEY=${2:-}
PROXY_DIR=${PROXY_DIR:-/data/coolify/proxy}
CERT_DIR=$PROXY_DIR/certs
DYNAMIC_DIR=$PROXY_DIR/dynamic

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;33m!!\033[0m %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -n "$CERT" ] && [ -n "$KEY" ] || die "usage: $0 <cert.pem> <key.pem>"
[ -r "$CERT" ] || die "cannot read $CERT"
[ -r "$KEY" ] || die "cannot read $KEY"
[ -d "$DYNAMIC_DIR" ] || die "$DYNAMIC_DIR not found — is Coolify's proxy installed?"

# --- sanity-check the pair ---------------------------------------------------
log "Checking certificate"
openssl x509 -in "$CERT" -noout -subject -dates -ext subjectAltName || die "not a valid certificate"

cert_mod=$(openssl x509 -in "$CERT" -noout -modulus | openssl md5)
key_mod=$(openssl rsa -in "$KEY" -noout -modulus 2>/dev/null | openssl md5)
if [ "$cert_mod" != "$key_mod" ]; then
  die "certificate and key do not match"
fi

# Warn if the cert does not look like a wildcard.
if ! openssl x509 -in "$CERT" -noout -ext subjectAltName | grep -q '\*\.'; then
  printf '\033[1;33m!!\033[0m no wildcard SAN found — per-subdomain hosts will not match\n' >&2
fi

# --- install -----------------------------------------------------------------
log "Installing certificate"
install -d -m 0755 "$CERT_DIR"
install -m 0644 "$CERT" "$CERT_DIR/origin.pem"
install -m 0600 "$KEY" "$CERT_DIR/origin.key"

log "Writing default-certificate config"
cat >"$DYNAMIC_DIR/zz-default-cert.yaml" <<'EOF'
# Managed by dotfiles/scripts/install-origin-cert.sh
# Serves the wildcard origin certificate for every TLS router that has no
# certificate of its own, so random subdomains work without per-host ACME.
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /traefik/certs/origin.pem
        keyFile: /traefik/certs/origin.key
EOF

log "Restarting the proxy"
docker restart coolify-proxy >/dev/null
sleep 5

# --- verify ------------------------------------------------------------------
log "Verifying"
subject=$(echo | openssl s_client -connect 127.0.0.1:443 -servername probe.local 2>/dev/null |
  openssl x509 -noout -subject 2>/dev/null || true)
if [ -n "$subject" ]; then
  printf '  served: %s\n' "$subject"
else
  printf '  \033[1;31mFAIL\033[0m no certificate served on :443\n' >&2
  printf '  check: docker logs --tail 50 coolify-proxy\n' >&2
  exit 1
fi

log "Done. Next: Cloudflare SSL mode → Full (strict); tunnel → https://localhost:443 (No TLS Verify)."
