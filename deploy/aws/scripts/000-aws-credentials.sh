#!/usr/bin/env bash
# 010-aws-credentials.sh - AWS-specific cloud-init per-instance script
# Runs before 001_onboot (cloud-init executes scripts in lexicographic order).
# Extracts S3 credentials from EC2 user-data and writes them to /opt/s3-server/.env.
#
# This script is AWS-specific because EC2 user-data is the standard way to pass
# initial configuration to instances. Other vendors use different mechanisms
# (cloud-init vendor-data, metadata service, etc.).

set -uo pipefail

ENV_FILE="/opt/s3-server/.env"
mkdir -p /opt/s3-server

S3_ACCESS_KEY=""
S3_SECRET_KEY=""
AUTO_UPDATE=""

USER_DATA_FILE="/var/lib/cloud/instance/user-data.txt"
USER_DATA=""

if [ -f "${USER_DATA_FILE}" ]; then
    USER_DATA="$(cat "${USER_DATA_FILE}")"
fi

# Only extracts specific key=value lines, never evaluates user-data as shell code.
if [ -n "${USER_DATA}" ]; then
    S3_ACCESS_KEY="$(echo "${USER_DATA}" | sed -nE 's/^\s*(export\s+)?s3_access_key\s*=\s*"?([^"\n]+?)"?\s*$/\2/p' | head -1 || true)"
    S3_SECRET_KEY="$(echo "${USER_DATA}" | sed -nE 's/^\s*(export\s+)?s3_secret_key\s*=\s*"?([^"\n]+?)"?\s*$/\2/p' | head -1 || true)"
    AUTO_UPDATE="$(echo "${USER_DATA}" | sed -nE 's/^\s*(export\s+)?auto_update\s*=\s*"?([^"\n]+?)"?\s*$/\2/p' | head -1 || true)"
fi

if [ -n "${S3_ACCESS_KEY}" ] || [ -n "${S3_SECRET_KEY}" ]; then
    echo "[010-aws-credentials] Writing S3 credentials to ${ENV_FILE}"
    cat > "${ENV_FILE}" <<EOF
S3_ACCESS_KEY=${S3_ACCESS_KEY}
S3_SECRET_KEY=${S3_SECRET_KEY}
EOF
    chmod 600 "${ENV_FILE}"
fi

# Auto-update flag file API
if [ "${AUTO_UPDATE}" = "false" ]; then
    touch /state/autoupdate.disabled 2>/dev/null || true
    rm -f /state/autoupdate.enabled 2>/dev/null || true
    echo "[010-aws-credentials] Auto-update disabled via user-data"
elif [ -f /state/autoupdate.disabled ]; then
    echo "[010-aws-credentials] Auto-update disabled (flag file present)"
else
    touch /state/autoupdate.enabled 2>/dev/null || true
    echo "[010-aws-credentials] Auto-update enabled"
fi

exit 0
