#!/usr/bin/env bash
#
# scripts/publish.sh — make a hostname deliberately public, or take it back.
#
#     ./scripts/publish.sh list
#     ./scripts/publish.sh publish   app.matiasagelvis.com
#     ./scripts/publish.sh unpublish app.matiasagelvis.com
#
# Publishing creates a *specific* Cloudflare Access application for the hostname
# with the Bypass policy, which overrides the `*.domain` wildcard app. Your
# default stays private; only named hosts become public.
#
# Credentials: ~/.config/cloudflare/access.env (600), containing
#     CF_API_TOKEN=...     # token with Account → Access: Apps and Policies: Edit
#     CF_ACCOUNT_ID=...
#     CF_BYPASS_POLICY=public (bypass access)   # policy name or ID
#
set -euo pipefail

ENV_FILE=${ENV_FILE:-$HOME/.config/cloudflare/access.env}
API=https://api.cloudflare.com/client/v4

log() { printf '\n==> %s\n' "$*"; }
die() {
  printf '!! %s\n' "$*" >&2
  exit 1
}

# --- json helpers (python3, so no jq dependency) -----------------------------
jget() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

api() {
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -s --max-time 20 -X "$method" "$API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H 'Content-Type: application/json' \
      --data "$body"
  else
    curl -s --max-time 20 -X "$method" "$API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN"
  fi
}

check() {
  python3 -c '
import sys, json
d = json.load(sys.stdin)
if not d.get("success", False):
    errs = "; ".join(f"{e.get(\"code\")}: {e.get(\"message\")}" for e in d.get("errors", []))
    sys.exit(f"API error: {errs}")
print(json.dumps(d.get("result")))
'
}

# --- config ------------------------------------------------------------------
[ -r "$ENV_FILE" ] || die "missing $ENV_FILE (see the header of this script)"
# shellcheck disable=SC1090
. "$ENV_FILE"
for v in CF_API_TOKEN CF_ACCOUNT_ID CF_BYPASS_POLICY; do
  [ -n "${!v:-}" ] || die "$v is not set in $ENV_FILE"
done

resolve_policy() {
  local want=$1
  api GET "/accounts/$CF_ACCOUNT_ID/access/policies" | check |
    python3 -c '
import sys, json
want = sys.argv[1]
pols = json.load(sys.stdin)
for p in pols:
    if p.get("id") == want or p.get("name") == want:
        print(p["id"]); break
else:
    sys.exit(f"no policy matching {want!r}")
' "$want"
}

find_app() {
  local host=$1
  api GET "/accounts/$CF_ACCOUNT_ID/access/apps" | check |
    python3 -c '
import sys, json
host = sys.argv[1]
for a in json.load(sys.stdin):
    # Access stores domain with an optional path; compare host only.
    if a.get("domain", "").split("/")[0] == host:
        print(a["id"]); break
' "$host"
}

cmd=${1:-}
host=${2:-}

case "$cmd" in
  list)
    log "Access applications"
    api GET "/accounts/$CF_ACCOUNT_ID/access/apps" | check |
      python3 -c '
import sys, json
rows = json.load(sys.stdin)
for a in sorted(rows, key=lambda x: x.get("domain", "")):
    print(f"  {a.get(\"domain\",\"?\"):45} {a.get(\"name\",\"\")}")
'
    ;;

  publish)
    [ -n "$host" ] || die "usage: $0 publish <hostname>"
    policy=$(resolve_policy "$CF_BYPASS_POLICY") || die "bypass policy not found: $CF_BYPASS_POLICY"
    existing=$(find_app "$host")
    if [ -n "$existing" ]; then
      log "$host already has an Access app ($existing) — nothing to do"
      exit 0
    fi
    log "Publishing $host (bypass policy $policy)"
    body=$(python3 -c '
import json, sys
host, policy = sys.argv[1], sys.argv[2]
print(json.dumps({
    "name": f"public: {host}",
    "domain": host,
    "type": "self_hosted",
    "session_duration": "24h",
    "policies": [{"id": policy, "precedence": 1}],
}))
' "$host" "$policy")
    api POST "/accounts/$CF_ACCOUNT_ID/access/apps" "$body" | check >/dev/null ||
      die "failed to create the Access app"
    log "Done. $host bypasses Access; everything else stays private."
    ;;

  unpublish)
    [ -n "$host" ] || die "usage: $0 unpublish <hostname>"
    id=$(find_app "$host")
    [ -n "$id" ] || {
      log "$host has no specific Access app — already covered by the wildcard (private)."
      exit 0
    }
    log "Removing Access app for $host ($id)"
    api DELETE "/accounts/$CF_ACCOUNT_ID/access/apps/$id" | check >/dev/null ||
      die "failed to delete the Access app"
    log "Done. $host now falls under the wildcard app (private)."
    ;;

  *)
    sed -n '2,20p' "$0"
    exit 2
    ;;
esac
