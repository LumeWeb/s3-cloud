#!/usr/bin/env bash
# validate.sh: Create a temp Droplet from the Packer snapshot, run DO's
# 99-img-check.sh validation script, then destroy the Droplet.
#
# Requires: doctl (authenticated), jq
# Env:      DO_SSH_KEY_ID:  DO SSH key fingerprint for temp droplet
#           DIGITALOCEAN_API_TOKEN: already saved via `doctl auth init`
set -euo pipefail

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

echo "==> Droplet $DROPLET_ID created. Waiting for SSH to become available..."
DROPLET_IP=$(doctl compute droplet get "$DROPLET_ID" \
  --format PublicIPv4 --no-header)

# Wait for SSH to be ready (cloud-init + first boot may take time)
echo "==> Droplet IP: $DROPLET_IP"
for i in $(seq 1 12); do
  if ssh -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o BatchMode=yes \
        -i "${HOME}/.ssh/id_ed25519" \
        root@"$DROPLET_IP" "echo ready" 2>/dev/null; then
    echo "==> SSH ready after ${i}0 seconds"
    break
  fi
  echo "    Attempt $i: SSH not ready, waiting 10s..."
  sleep 10
done

echo "==> Downloading and running img-check..."
IMG_CHECK_URL="https://raw.githubusercontent.com/digitalocean/marketplace-partners/master/scripts/99-img-check.sh"

# Run validation; capture exit code
set +e
ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -i "${HOME}/.ssh/id_ed25519" \
    root@"$DROPLET_IP" \
    "bash -s" < <(curl -fsSL "$IMG_CHECK_URL")
EXIT_CODE=$?
set -e

echo "==> img-check exited with code $EXIT_CODE"

echo "==> Destroying validation Droplet $DROPLET_ID..."
doctl compute droplet delete -f "$DROPLET_ID"

if [ "$EXIT_CODE" -ne 0 ]; then
  echo "Error: image validation failed" >&2
  exit 1
fi

echo "==> Validation passed"
