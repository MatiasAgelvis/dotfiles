#!/bin/sh
# Clone on first run, then hand over to the repo's own runner.
set -eu

REPO_URL=${STARISK_REPO_URL:-https://github.com/MatiasAgelvis/starisk.git}
BASE=${STARISK_BASE_BRANCH:-develop}

if [ ! -d /workspace/.git ]; then
  echo "[entrypoint] cloning $REPO_URL ($BASE) into /workspace"
  git clone --quiet --branch "$BASE" "$REPO_URL" /workspace
else
  # The runner leaves the checkout on its bot branch; the module lives on BASE.
  git -C /workspace fetch --quiet origin "$BASE" || true
  git -C /workspace switch --quiet "$BASE" 2>/dev/null || true
fi

# The volume may be mounted from a different uid on some setups.
git config --global --add safe.directory /workspace

cd /workspace/pipeline
exec python3 -m starisk.nightly "$@"
