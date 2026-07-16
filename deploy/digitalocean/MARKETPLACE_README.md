# DigitalOcean Marketplace Listing

## App Name
Pinner S3 Server

## Short Description
Self-hosted, private S3-compatible object storage with automatic updates.

## Description
Pinner S3 Server is a lightweight, self-hosted S3-compatible object storage service that runs in Docker. It includes a built-in update sidecar that automatically checks for and applies new container image releases. Deploy it on a DigitalOcean Droplet with one click and start managing your own object storage.

### Features
- S3-compatible API on port 80
- Automatic container image updates (ON by default)
- Docker Compose-based deployment for easy management
- Health checks and auto-restart on failure
- Isolated networking between frontend and backend services

### Getting Started
1. Create a Droplet from this 1-Click app.
2. The service starts automatically on first boot and pulls the latest container images.
3. Access the S3-compatible API at `http://your-droplet-ip/`.

### Configuration
- **Disable auto-updates:** `touch /state/autoupdate.disabled`
- **Force manual update:** `touch /state/update.trigger`
- **View updater logs:** `cat /state/updater.log`
- **docker-compose.yml location:** `/opt/s3-server/docker-compose.yml`

### Requirements
- Minimum Droplet size: `s-1vcpu-2gb`
- Operating system: Ubuntu 22.04

### Support
For issues and documentation, visit: https://github.com/LumeWeb/s3-server

## Categories
Storage, Developer Tools

## Logo / Screenshots
Submit via DigitalOcean Vendor Portal: https://marketplace.digitalocean.com/vendors

## User-Data Support
This 1-Click app supports DigitalOcean user-data for first-boot configuration.
Add user-data scripts to customize the Droplet on first boot (e.g., to disable
auto-updates: `#!/bin/bash\ntouch /state/autoupdate.disabled`).

---

Version and image ID are submitted to the Vendor Portal API at release time.
See `submit.py` and the Makefile `submit` target for automation details.
