#!/usr/bin/env bash
# validate.sh: Create a temp EC2 instance from the Packer AMI,
# run AWS Marketplace compliance checks, then terminate.
#
# Requires: aws CLI, jq
# Env:      AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION (or AWS_DEFAULT_REGION)
#           CI_BUILD_SSH_KEY: base64-encoded ed25519 private key written to ~/.ssh/id_ed25519
set -euo pipefail

# AWS uses ubuntu user, not root
export SSH_USER="ubuntu"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../shared/scripts/lib/compliance-checks.sh"

MANIFEST="${1:-manifest.json}"

if [ ! -f "$MANIFEST" ]; then
  echo "Error: manifest not found: $MANIFEST" >&2
  echo "Run 'make build' first." >&2
  exit 1
fi

AMI_ID=$(jq -r '.builds[-1].artifact_id' "$MANIFEST" | sed 's/^[^:]*://')

if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "null" ]; then
  echo "Error: could not extract AMI ID from manifest" >&2
  exit 1
fi

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
INSTANCE_LABEL="pinner-s3-aws-validate-$(date +%s)"

# Default to the smallest instance type for validation
INSTANCE_TYPE="${AWS_VALIDATE_INSTANCE_TYPE:-t3.small}"

# Look up a subnet in the default VPC, avoiding us-east-1e (no t3.small support)
SUBNET_ID="${AWS_VALIDATE_SUBNET_ID:-}"
if [ -z "$SUBNET_ID" ]; then
  SUBNET_INFO=$(aws ec2 describe-subnets \
    --filters "Name=default-for-az,Values=true" \
    --query 'Subnets[*].[SubnetId,AvailabilityZone]' --output text --region "$AWS_REGION")
  while read -r sub az; do
    if [ "$az" != "us-east-1e" ]; then
      SUBNET_ID="$sub"
      break
    fi
  done <<< "$SUBNET_INFO"
fi
if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" = "None" ]; then
  echo "Error: could not determine subnet; set AWS_VALIDATE_SUBNET_ID" >&2
  exit 1
fi

SG_ID=$(aws ec2 create-security-group   --group-name "$INSTANCE_LABEL"   --description "Temporary validation security group for S3 Server"   --query 'GroupId' --output text --region "$AWS_REGION")

# Open port 22 for SSH and port 80 for health checks from current IP
CURRENT_IP=$(curl -fsSL https://checkip.amazonaws.com 2>/dev/null || echo "")
if [ -n "$CURRENT_IP" ]; then
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr "${CURRENT_IP}/32" \
    --region "$AWS_REGION" >/dev/null
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 80 --cidr "${CURRENT_IP}/32" \
    --region "$AWS_REGION" >/dev/null
fi

cleanup() {
  if [ -n "${INSTANCE_ID:-}" ]; then
    echo "==> Terminating validation instance $INSTANCE_ID..."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null 2>&1 || true
    echo "==> Waiting for instance to terminate..."
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" >/dev/null 2>&1 || true
  fi
  if [ -n "${SG_ID:-}" ]; then
    echo "==> Deleting temporary security group $SG_ID..."
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" >/dev/null 2>&1 || true
  fi
  ssh_close "${INSTANCE_IP:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "==> Creating validation instance from AMI $AMI_ID in $AWS_REGION..."

# Build user-data for rescue password if provided
USER_DATA=""
if [ -n "${RESCUE_PASSWORD:-}" ]; then
  USER_DATA=$(printf '#cloud-config\npassword: %s\nchpasswd: { expire: False }\nssh_pwauth: True\n' "$RESCUE_PASSWORD" | base64 -w0)
  echo "==> Rescue password configured for serial console access"
fi

RUN_INSTANCE_ARGS=(
  --image-id "$AMI_ID"
  --instance-type "$INSTANCE_TYPE"
  --subnet-id "$SUBNET_ID"
  --security-group-ids "$SG_ID"
  --query 'Instances[0].InstanceId'
  --output text
  --region "$AWS_REGION"
)

if [ -n "$USER_DATA" ]; then
  RUN_INSTANCE_ARGS+=(--user-data "$USER_DATA")
fi

INSTANCE_ID=$(aws ec2 run-instances "${RUN_INSTANCE_ARGS[@]}")

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "Error: failed to create validation instance" >&2
  exit 1
fi

echo "==> Instance $INSTANCE_ID created. Waiting for status checks..."
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"

INSTANCE_IP=$(aws ec2 describe-instances   --instance-ids "$INSTANCE_ID"   --query 'Reservations[0].Instances[0].PublicIpAddress'   --output text   --region "$AWS_REGION")

if [ -z "$INSTANCE_IP" ] || [ "$INSTANCE_IP" = "None" ]; then
  echo "Error: could not get public IP for instance $INSTANCE_ID" >&2
  exit 1
fi

echo "==> Instance IP: $INSTANCE_IP"
wait_for_ssh "$INSTANCE_IP" 30 || exit 1

wait_for_cloud_init "$INSTANCE_IP" 12

# --- AWS Marketplace compliance checks ---
echo ""
run_compliance_checks "$INSTANCE_IP"

# AWS-specific: root login disabled and PasswordAuthentication no
ROOT_LOGIN=$(ssh_run "$INSTANCE_IP" "grep -E '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | awk '{print \$2}' || echo missing")
PASS_AUTH=$(ssh_run "$INSTANCE_IP" "grep -E '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print \$2}' || echo missing")

if [ "$ROOT_LOGIN" = "no" ]; then
  echo "  PASS: root login disabled"
else
  echo "  FAIL: PermitRootLogin is $ROOT_LOGIN (expected no)"
  COMPLIANCE_FAIL=1
fi

if [ "$PASS_AUTH" = "no" ]; then
  echo "  PASS: PasswordAuthentication disabled"
else
  echo "  FAIL: PasswordAuthentication is $PASS_AUTH (expected no)"
  COMPLIANCE_FAIL=1
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
