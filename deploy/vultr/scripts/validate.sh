#!/usr/bin/env bash
# validate.sh: Create a temp Vultr instance from the Packer snapshot,
# run health checks and marketplace compliance validation, then destroy.
#
# Requires: vultr-cli (authenticated), jq
# Env:      VULTR_API_KEY: already configured via `vultr-cli` auth
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

SNAPSHOT_ID=$(jq -r '.builds[-1].artifact_id' "$MANIFEST")

if [ -z "$SNAPSHOT_ID" ] || [ "$SNAPSHOT_ID" = "null" ]; then
  echo "Error: could not extract snapshot ID from manifest" >&2
  exit 1
fi

INSTANCE_LABEL="pinner-s3-vultr-validate-$(date +%s)"

echo "==> Creating validation instance from snapshot $SNAPSHOT_ID..."

SSH_KEY_ARGS=()
if [ -n "${VULTR_SSH_KEY_ID:-}" ]; then
  SSH_KEY_ARGS=("--ssh-keys=$VULTR_SSH_KEY_ID")
fi

INSTANCE_ID=$(vultr-cli instance create \
  --region="ewr" \
  --plan="vc2-1c-2gb" \
  --snapshot="$SNAPSHOT_ID" \
  --label="$INSTANCE_LABEL" \
  --host="s3-server-validate" \
  "${SSH_KEY_ARGS[@]}" \
  --output=json | jq -r '.instance.id')

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
  echo "Error: failed to create validation instance" >&2
  exit 1
fi

cleanup() {
  if [ -n "${INSTANCE_ID:-}" ]; then
    echo "==> Destroying validation instance $INSTANCE_ID..."
    vultr-cli instance delete "$INSTANCE_ID" 2>/dev/null || true
  fi
  ssh_close "$INSTANCE_IP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "==> Instance $INSTANCE_ID created. Waiting for it to become active..."

# Wait for instance to be active AND powered on.
for i in $(seq 1 90); do
  JSON=$(vultr-cli instance get "$INSTANCE_ID" --output=json 2>/dev/null || echo "{}")
  STATUS=$(echo "$JSON" | jq -r '.instance.status // empty' 2>/dev/null || echo "")
  POWER=$(echo "$JSON" | jq -r '.instance.power_status // empty' 2>/dev/null || echo "")
  if [ "$STATUS" = "active" ] && [ "$POWER" = "running" ]; then
    echo "==> Instance is active and running after $((i * 10)) seconds"
    break
  fi
  echo "    Attempt $i: status=$STATUS power=$POWER, waiting 10s..."
  sleep 10
done

if [ "$STATUS" != "active" ] || [ "$POWER" != "running" ]; then
  echo "Error: instance did not become active+running within 900 seconds" >&2
  exit 1
fi

INSTANCE_IP=$(vultr-cli instance get "$INSTANCE_ID" --output=json | jq -r '.instance.main_ip')

if [ -z "$INSTANCE_IP" ] || [ "$INSTANCE_IP" = "null" ] || [ "$INSTANCE_IP" = "0.0.0.0" ]; then
  echo "Error: could not get public IP for instance $INSTANCE_ID" >&2
  exit 1
fi

echo "==> Instance IP: $INSTANCE_IP"
# Vultr instances take longer to boot than DO droplets — 900s timeout.
wait_for_ssh "$INSTANCE_IP" 90 || exit 1

wait_for_cloud_init "$INSTANCE_IP" 12

# --- Shared compliance checks ---
echo ""
run_compliance_checks "$INSTANCE_IP"

# Vultr-specific: kernel option
VULTR_KERNEL=$(ssh_run "$INSTANCE_IP" "grep -c vultr /etc/default/grub 2>/dev/null || echo 0")
if [ "$VULTR_KERNEL" != "0" ]; then
  echo "  PASS: Vultr kernel option set"
else
  echo "  WARN: Vultr kernel option not found in grub config"
fi

# --- Health checks ---
run_health_checks "$INSTANCE_IP"

if [ "$COMPLIANCE_FAIL" -ne 0 ]; then
  echo "Error: marketplace compliance checks failed" >&2
  exit 1
fi

if [ "$HEALTH_EXIT" -ne 0 ] && [ "$HTTP_CODE" != "200" ]; then
  echo "Error: validation failed (service not active and healthz not 200)" >&2
  exit 1
fi

echo "==> All checks passed"
