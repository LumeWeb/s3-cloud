#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# s3-server update sidecar - polls GHCR for new :latest digests and
# recreates the s3-server container.
#
# Flag-file API (shared /state volume, panel <-> sidecar):
#   /state/autoupdate.enabled   - EXISTS => auto-update on (default ON)
#   /state/autoupdate.disabled  - EXISTS => auto-update off (takes precedence)
#   /state/update.trigger       - EXISTS => force update on next poll (one-shot)
#   /state/updater.log          - append-only log
#   /state/last-digest          - last-applied image digest

set -euo pipefail

[ "${DEBUG:-0}" = "1" ] && set -x

INTERVAL="${UPDATE_INTERVAL:-21600}"   # seconds between digest polls (default 6h)
PROJECT_DIR="${UPDATER_PROJECT_DIR:-${COMPOSE_PROJECT_DIR:-/opt/s3-server}}"
SERVICE="${COMPOSE_SERVICE:-s3-server}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-s3-deployment}"
export COMPOSE_PROJECT_NAME

IMG_FQDN="ghcr.io"
IMG_REPO="lumeweb/s3-server"
IMG_TAG="latest"
IMG="${IMG_FQDN}/${IMG_REPO}:${IMG_TAG}"

CONFIG_DIR="${PROJECT_DIR}"
STATE_DIR="/state"
FL_LOG="${STATE_DIR}/updater.log"
FL_LAST="${STATE_DIR}/last-digest"
FL_ENABLE="${STATE_DIR}/autoupdate.enabled"
FL_DISABLE="${STATE_DIR}/autoupdate.disabled"
FL_TRIGGER="${STATE_DIR}/update.trigger"

mkdir -p "${STATE_DIR}"

cleanup() {
  log "Received termination signal; shutting down."
  exit 0
}
trap cleanup TERM INT

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(stamp)] $*" | tee -a "${FL_LOG}" >/dev/null; }

# Auto-update is ON by default. FL_DISABLE takes precedence over FL_ENABLE.
# If neither flag exists, default is ON (VM deployments).
is_autoupdate() {
  [ -f "${FL_DISABLE}" ] && return 1   # explicit disable wins
  [ -f "${FL_ENABLE}" ] && return 0   # explicit enable
  return 0                              # default: ON
}

ghcr_token() {
  local resp http_code token
  resp="$(curl -sSL -w '\n%{http_code}' \
    "https://${IMG_FQDN}/token?service=${IMG_FQDN}&scope=repository:${IMG_REPO}:pull" 2>/dev/null)" || {
    log "ERROR: curl failed while fetching GHCR token"
    return 1
  }
  http_code="$(echo "${resp}" | tail -1)"
  if [ "${http_code}" != "200" ]; then
    log "ERROR: GHCR token endpoint returned HTTP ${http_code}"
    return 1
  fi
  token="$(echo "${resp}" | sed '$d' | jq -r '.token // empty' 2>/dev/null)" || true
  if [ -z "${token}" ]; then
    log "ERROR: GHCR token not found in response"
    return 1
  fi
  echo "${token}"
}

remote_digest() {
  local token hdr
  token="$(ghcr_token)" || return 1
  hdr="${STATE_DIR}/.manifest-headers"
  local auth_header="Authorization: Bearer ${token}"
  local accept_header="Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"
  rm -f "${hdr}"
  if ! curl -fsSL \
       -H "${auth_header}" \
       -H "${accept_header}" \
       "https://${IMG_FQDN}/v2/${IMG_REPO}/manifests/${IMG_TAG}" \
       -D "${hdr}" -o /dev/null; then
    rm -f "${hdr}"
    return 1
  fi
  grep -i '^docker-content-digest:' "${hdr}" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r'
  rm -f "${hdr}"
}

local_digest() {
  [ -f "${FL_LAST}" ] && cat "${FL_LAST}"
}

do_update() {
  log "Pulling & recreating ${SERVICE} (${IMG})..."
  local -a compose_opts=(-f "${CONFIG_DIR}/docker-compose.yml" -p "${COMPOSE_PROJECT_NAME}")
  if docker compose "${compose_opts[@]}" pull "${SERVICE}" \
     && docker compose "${compose_opts[@]}" up -d "${SERVICE}"; then
    # Old :latest becomes <none>:<none> after retag; reference filter
    # won't match it. Project-scoped dangling prune handles cleanup.
    docker image prune -f \
      --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
      >/dev/null 2>&1 || true
    log "Update OK."
    return 0
  fi
  log "ERROR: update pipeline failed (see docker output above)."
  return 1
}

poll_once() {
  if [ -f "${FL_TRIGGER}" ]; then
    log "Manual update trigger detected."
    local r
    r="$(remote_digest || true)"
    if [ -n "${r}" ]; then
      if do_update; then
        rm -f "${FL_TRIGGER}"
        echo "${r}" > "${FL_LAST}"
        return 0
      fi
    else
      if do_update; then
        # Re-fetch digest after update so FL_LAST is not stale.
        # Fall back to the local image digest so a transient remote
        # outage does not leave FL_LAST stale and trigger a redundant
        # re-update on the next cycle.
        r="$(remote_digest || true)"
        if [ -z "${r}" ]; then
          r="$(docker images --digests --filter "reference=${IMG_FQDN}/${IMG_REPO}" \
              --format '{{.Digest}}' | head -1)"
        fi
        if [ -n "${r}" ]; then
          echo "${r}" > "${FL_LAST}"
          rm -f "${FL_TRIGGER}"
          return 0
        else
          log "WARN: could not stamp last-digest; leaving trigger for next cycle."
        fi
      fi
    fi
    # Trigger not consumed — write a backoff marker so
    # wait_for_next_cycle skips the trigger shortcut and sleeps
    # the full interval before retrying.
    touch "${STATE_DIR}/.trigger-backoff"
    return 1
  fi

  if ! is_autoupdate; then
    log "Auto-update disabled; skipping."
    return 0
  fi

  local r l
  r="$(remote_digest || true)"
  [ -z "${r}" ] && { log "ERROR: cannot fetch remote digest; skipping."; return 1; }
  l="$(local_digest || true)"

  if [ "${r}" != "${l}" ]; then
    log "Digest changed: ${l:-<none>} -> ${r}"
    if do_update; then
      echo "${r}" > "${FL_LAST}"
    fi
  else
    log "Digest unchanged (${r})."
    [ -f "${FL_LAST}" ] || echo "${r}" > "${FL_LAST}"
  fi
}

# Sleep in short increments so the trigger file is checked frequently.
# Returns 0 immediately if a trigger appears during the wait — but only
# if the previous trigger attempt succeeded (no .trigger-backoff marker).
# On backoff, sleeps the full interval to avoid hammering GHCR/Docker.
wait_for_next_cycle() {
  local elapsed=0
  local backoff=0
  [ -f "${STATE_DIR}/.trigger-backoff" ] && backoff=1
  while [ "${elapsed}" -lt "${INTERVAL}" ]; do
    if [ "${backoff}" -eq 0 ] && [ "${elapsed}" -gt 0 ] && [ -f "${FL_TRIGGER}" ]; then
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  rm -f "${STATE_DIR}/.trigger-backoff"
  return 0
}

log "=== s3-server sidecar updater starting (interval=${INTERVAL}s, service=${SERVICE}) ==="

touch "${FL_ENABLE}"

while true; do
  poll_once || true
  wait_for_next_cycle
done
