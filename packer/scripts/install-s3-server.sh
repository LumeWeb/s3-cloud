#!/usr/bin/env bash
# install-s3-server.sh - Shared Packer provisioner for all cloud marketplace VMs

set -euo pipefail

echo "=== S3 Server Packer Provisioner ==="
echo "Installing Docker Engine + docker-compose-plugin..."

# Docker convenience script handles apt/dnf package setup
curl -fsSL https://get.docker.com | sh
systemctl enable docker

# Install docker-compose-plugin explicitly (convenience script may not
# always include it depending on the base image)
if ! docker compose version >/dev/null 2>&1; then
    echo "docker-compose-plugin not found via convenience script; installing manually..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq docker-compose-plugin
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y docker-compose-plugin
    elif command -v yum >/dev/null 2>&1; then
        yum install -y docker-compose-plugin
    else
        echo "WARNING: Could not install docker-compose-plugin via package manager."
        echo "         Falling back to downloading compose binary."
        COMPOSE_VERSION="v2.29.2"
        mkdir -p /usr/local/lib/docker/cli-plugins
        curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-$(uname -m)" \
            -o /usr/local/lib/docker/cli-plugins/docker-compose
        curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-$(uname -m).sha256" \
            -o /tmp/docker-compose.sha256
        expected="$( awk '{print $1}' /tmp/docker-compose.sha256 )"
        actual="$( sha256sum /usr/local/lib/docker/cli-plugins/docker-compose | awk '{print $1}' )"
        [ "${actual}" = "${expected}" ] || { echo "ERROR: SHA256 mismatch for docker-compose binary" >&2; exit 1; }
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    fi
fi

echo "Docker version:"
docker --version
echo "Docker Compose version:"
docker compose version

echo "Creating directories..."
mkdir -p /opt/s3-server

# Detect host docker gid for socket access
DOCKER_GID="$(getent group docker | cut -d: -f3)"
echo "Host docker gid: ${DOCKER_GID}"

# Packer's file provisioner uploads the repo-root docker-compose.yml to
# /tmp/docker-compose.yml before this script runs. If it's not there,
# we write a working reference file.
if [ -f /tmp/docker-compose.yml ]; then
    echo "Copying docker-compose.yml from uploaded file..."
    cp /tmp/docker-compose.yml /opt/s3-server/docker-compose.yml
else
    echo "WARNING: /tmp/docker-compose.yml not found. Writing reference compose file."
    cat > /opt/s3-server/docker-compose.yml << COMPOSE
name: s3-deployment

services:
  s3-server:
    image: ghcr.io/lumeweb/s3-server:latest
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - s3-data:/data
      - s3-state:/state
    networks:
      - frontend
    healthcheck:
      test: ["CMD-SHELL", "wget --spider -q http://localhost:8080/_panel/healthz || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

  updater:
    image: ghcr.io/lumeweb/s3-server-updater:latest
    restart: unless-stopped
    depends_on:
      s3-server:
        condition: service_healthy
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
    group_add:
      - "${DOCKER_GID}"
    environment:
      - UPDATE_INTERVAL=21600
      - UPDATER_PROJECT_DIR=/opt/s3-server
      - COMPOSE_SERVICE=s3-server
      - DOCKER_GID=${DOCKER_GID}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./:/opt/s3-server:ro
      - s3-state:/state
    networks:
      - frontend
      - backend

volumes:
  s3-data:
  s3-state:

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    internal: true
COMPOSE
fi

echo "Auto-update is enabled by default (sidecar creates the flag on startup)."

# Write .env so docker compose and systemd both pick up DOCKER_GID
cat > /opt/s3-server/.env << EOF
DOCKER_GID=${DOCKER_GID}
EOF

echo "Creating systemd service..."
cat > /etc/systemd/system/s3-server.service << 'EOF'
[Unit]
Description=S3 Server (Docker Compose)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/s3-server
EnvironmentFile=/opt/s3-server/.env
ExecStart=/usr/bin/docker compose -f /opt/s3-server/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f /opt/s3-server/docker-compose.yml down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable s3-server.service

# Don't start s3-server.service during the Packer build; the container image
# is pulled by the sidecar on first boot of the provisioned VM, not during
# image creation.

# /data and /state are Docker named volumes (s3-data, s3-state).
# /data is for the DB and upload staging. /state is for sidecar flags.

cat > /opt/s3-server/README.md << 'EOF'
# S3 Server VM Image

Pinner.xyz S3 Server - Private, zero-knowledge self-hosted S3-compatible object storage.

## Quick Start
1. **Boot the VM** - the s3-server systemd service starts automatically.
2. **Verify**: `systemctl status s3-server` should be active.
3. **Access**: S3 API on port 8080.

## Auto-Update
Auto-update is **enabled by default**. The update sidecar checks for new
container images every 6 hours. To disable:
```bash
docker exec s3-deployment-updater-1 touch /state/autoupdate.disabled
```
Re-enable with:
```bash
docker exec s3-deployment-updater-1 rm /state/autoupdate.disabled
```
No restart needed.

## Directories
- `/opt/s3-server/` - docker-compose.yml and configuration
- Docker named volumes: `s3-data` (DB + upload staging), `s3-state` (sidecar state)
EOF

echo "=== Provisioner complete ==="
echo "S3 Server image prepared successfully."
