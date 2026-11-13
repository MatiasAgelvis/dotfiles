#!/bin/sh
# Clone on first run, then hand over to the repo's own runner.
set -eu

REPO_URL=${STARISK_REPO_URL:-https://github.com/MatiasAgelvis/starisk.git}

if [ ! -d /workspace/.git ]; then
  echo "[entrypoint] cloning $REPO_URL into /workspace"
  git clone --quiet "$REPO_URL" /workspace
fi

# The volume may be mounted from a different uid on some setups.
git config --global --add safe.directory /workspace

cd /workspace/pipeline
exec python3 -m starisk.nightly "$@"
