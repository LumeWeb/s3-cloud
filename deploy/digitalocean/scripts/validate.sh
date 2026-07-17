#!/usr/bin/env bash
# validate.sh: Create a temp Droplet from the Packer snapshot, run DO's
# 99-img-check.sh validation script, then destroy the Droplet.
#
# Requires: doctl (authenticated), jq
# Env:      DO_SSH_KEY_ID:  DO SSH key fingerprint for temp droplet
#           DIGITALOCEAN_API_TOKEN: already saved via `doctl auth init`
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../shared/scripts/lib/compliance-checks.sh"

MANIFEST="${1:-manifest.json}"

if [ ! -f "$MANIFEST" ]; then
  echo "Error: manifest not found: $MANIFEST" >&2
  echo "Run 'make build' first." >&2
  exit 1
fi

if [ -z "${DO_SSH_KEY_ID:-}" ]; then
  echo "Error: DO_SSH_KEY_ID is required (DO SSH key fingerprint)" >&2
  exit 1
fi

SNAPSHOT_ID=$(jq -r '.builds[-1].artifact_id | split(":")[1]' "$MANIFEST")

echo "==> Creating validation Droplet from snapshot $SNAPSHOT_ID..."
DROPLET_ID=$(doctl compute droplet create pinner-s3-do-imgcheck \
  --image "$SNAPSHOT_ID" \
  --size s-1vcpu-1gb \
  --region nyc3 \
  --ssh-keys "$DO_SSH_KEY_ID" \
  --wait \
  --format ID \
  --no-header)

cleanup() {
  if [ -n "${DROPLET_ID:-}" ]; then
    echo "==> Destroying validation Droplet $DROPLET_ID..."
    doctl compute droplet delete -f "$DROPLET_ID" 2>/dev/null || true
  fi
  ssh_close "$DROPLET_IP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "==> Droplet $DROPLET_ID created. Waiting for SSH to become available..."
DROPLET_IP=$(doctl compute droplet get "$DROPLET_ID" \
  --format PublicIPv4 --no-header)

echo "==> Droplet IP: $DROPLET_IP"
wait_for_ssh "$DROPLET_IP" 30 || exit 1

wait_for_cloud_init "$DROPLET_IP" 12

# --- DO marketplace validation (official script) ---
echo "==> Downloading and running DO 99-img-check.sh..."
IMG_CHECK_URL="https://raw.githubusercontent.com/digitalocean/marketplace-partners/master/scripts/99-img-check.sh"

set +e
IMG_CHECK_OUTPUT=$(ssh -T "${SSH_BASE_OPTS[@]}" "root@$DROPLET_IP" \
    "bash -s" < <(curl -fsSL "$IMG_CHECK_URL") 2>&1)
IMG_CHECK_EXIT=$?
set -e

# Expected [FAIL] items on validation droplets (not image defects):
#   - authorized_keys: DO injects an SSH key on droplet creation
#   - DigitalOcean directory detected: expected on any DO droplet
IMG_CHECK_FILTERED=$(echo "$IMG_CHECK_OUTPUT" \
  | sed 's/\[FAIL\].*authorized_keys/[EXPECTED] authorized_keys (injected by DO on droplet creation)/' \
  | sed 's/\[FAIL\].*DigitalOcean directory detected/[INFO] DigitalOcean directory detected (expected on DO droplet)/')

echo "$IMG_CHECK_FILTERED"

REAL_FAILURES=$(echo "$IMG_CHECK_FILTERED" | grep "\[FAIL\]" || true)
if [ -n "$REAL_FAILURES" ]; then
  echo "==> img-check FAILED:"
  echo "$REAL_FAILURES"
  IMG_CHECK_EXIT=1
else
  echo "==> img-check passed (expected items excluded)"
  IMG_CHECK_EXIT=0
fi

# --- Shared compliance checks ---
echo ""
run_compliance_checks "$DROPLET_IP"

# --- Health checks ---
run_health_checks "$DROPLET_IP"

if [ "$IMG_CHECK_EXIT" -ne 0 ]; then
  echo "Error: DO img-check validation failed" >&2
  exit 1
fi

if [ "$COMPLIANCE_FAIL" -ne 0 ]; then
  echo "Error: shared compliance checks failed" >&2
  exit 1
fi

if [ "$HEALTH_EXIT" -ne 0 ] && [ "$HTTP_CODE" != "200" ]; then
  echo "Error: validation failed (service not active and healthz not 200)" >&2
  exit 1
fi

echo "==> All checks passed"
