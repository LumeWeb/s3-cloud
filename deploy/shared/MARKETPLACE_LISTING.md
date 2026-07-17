# Marketplace Listing

## App Name

Pinner S3 Server

## Short Description

Self-hosted, private S3-compatible object storage with automatic updates.

## Description

Pinner S3 Server is a lightweight, self-hosted S3-compatible object storage service that runs in Docker. It includes a built-in update sidecar that automatically checks for and applies new container image releases. Deploy it on a cloud compute instance and start managing your own object storage.

### Features

- S3-compatible API on port 80
- Automatic container image updates (ON by default)
- Docker Compose-based deployment for easy management
- Health checks and auto-restart on failure
- Isolated networking between frontend and backend services

### Getting Started

1. Deploy the app from the cloud marketplace.
2. The service starts automatically on first boot and pulls the latest container images.
3. Access the S3-compatible API at `http://your-server-ip/`.

### Configuration

- **Disable auto-updates:** `touch /state/autoupdate.disabled`
- **Force manual update:** `touch /state/update.trigger`
- **View updater logs:** `cat /state/updater.log`
- **docker-compose.yml location:** `/opt/s3-server/docker-compose.yml`

### Support

For issues and documentation, visit: https://github.com/LumeWeb/s3-server

## Categories

Storage, Developer Tools
