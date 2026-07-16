#!/bin/sh
set -e

# Fix /state ownership — named volumes are initialized by the first
# container (s3-server), which may leave /state root-owned.
mkdir -p /state
chown 1000:1000 /state

# Preserve the host docker GID supplementary group that group_add
# injected. su-exec's initgroups would otherwise drop it, breaking
# socket access. Create a group with the host GID and add appuser.
if [ -n "${DOCKER_GID:-}" ]; then
  addgroup -g "${DOCKER_GID}" docker-host 2>/dev/null || true
  addgroup appuser docker-host 2>/dev/null || true
fi

# Drop to uid 1000 and run the updater.
exec su-exec appuser /usr/local/bin/updater.sh
