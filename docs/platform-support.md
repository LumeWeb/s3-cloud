# Platform Support Matrix

Deployment targets for s3-server. All use the same Docker image (`ghcr.io/lumeweb/s3-server:latest`). Per-platform configs are added incrementally as providers are onboarded.

## Self-Hosted Docker

| Platform | Install | Update | Difficulty | Docs |
|---|---|---|---|---|
| Docker Compose | `docker compose up -d` | Sidecar or `docker compose pull && up -d` | Easy | - |

## Cloud VM Marketplaces

_Platform configs will be added here as providers are onboarded._

## PaaS

_Platform configs will be added here as providers are onboarded._

## Kubernetes

_Platform configs will be added here as providers are onboarded._

## Update Mechanism Summary

| Environment | Update Model | Panel UI | Sidecar |
|---|---|---|---|
| Docker Compose | Sidecar in compose | Auto-update toggle + manual "update now" button | Yes |
| Cloud VMs | Sidecar (Packer pre-installed) | Auto-update toggle + manual "update now" button | Yes |
| PaaS | Platform-native | None (platform manages updates) | No |
| Kubernetes | Manual helm upgrade / redeploy | Read-only status badge (no toggle/button) | No |

## Architecture

- **Image**: `ghcr.io/lumeweb/s3-server:latest` (amd64 + arm64)
- **Updater image**: `ghcr.io/lumeweb/s3-server-updater:latest` (multi-arch, built by this repo's CI)
- **Binary**: `s3-server` (Go, SQLite, port 8080)
- **Update sidecar**: polls GHCR `:latest` every 6h, compares digest, recreates container on change (~170 lines bash)
- **Sidecar flag files** (shared `/state` volume): `autoupdate.enabled`, `autoupdate.disabled`, `update.trigger`, `last-digest`, `updater.log`
- No `os/exec` in s3-server, no tini, no Docker-in-Docker, no Watchtower
