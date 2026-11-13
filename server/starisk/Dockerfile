# Starisk nightly runner.
#
# One container per run, no services, no ports. The repo is cloned into the
# /workspace volume on first run and updated by the runner's own `prepare()`.
#
# node:24-slim gives us node 24 (for web/scripts/sync-data.mjs); Debian's
# python3 is 3.11, which satisfies the repo's `requires-python >= 3.10`.
FROM node:24-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ENV PYTHONUNBUFFERED=1 \
    GIT_TERMINAL_PROMPT=0

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
