# S3 Deployment

Multi-platform deployment configs for [s3-server](https://github.com/LumeWeb/s3-server) - Pinner.xyz S3 Server: private, zero-knowledge self-hosted S3-compatible object storage.

## Overview

Single Docker image deployed across multiple platforms. This repo contains the shared foundation: standalone Docker Compose, update sidecar, CI pipeline, and shared Packer provisioner. Per-platform configs are added incrementally.

## Architecture

- **Image**: `ghcr.io/lumeweb/s3-server:latest` (amd64 + arm64)
- **Binary**: `s3-server` (Go, SQLite, port 8080)
- **Update sidecar**: `ghcr.io/lumeweb/s3-server-updater:latest` - polls GHCR :latest every 6h, compares digest, pulls and restarts on change
- **Panel UI**: Platforms with the sidecar show an auto-update on/off toggle and a manual "update now" button.

## Project Structure

```
s3-cloud/
├── docker-compose.yml              # Standalone deployment (s3-server + sidecar)
├── deploy/                         # Per-platform configs (added incrementally)
├── packer/
│   └── scripts/
│       └── install-s3-server.sh    # Shared VM provisioning script
├── sidecar/                        # Update sidecar
│   ├── Dockerfile.updater
│   └── updater.sh
├── docs/
│   └── platform-support.md         # Platform support matrix
└── .github/workflows/
    └── docker-publish.yml          # Sidecar multi-arch build pipeline
```

## Quick Start

```bash
# Standalone Docker Compose
export DOCKER_GID=$(getent group docker | cut -d: -f3)
docker compose up -d

# Access the S3 API
curl http://localhost:8080
```

## Docs

- [Platform Support Matrix](docs/platform-support.md)

## License

MIT
