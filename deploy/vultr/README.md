# Pinner S3 Server: Vultr Marketplace Deployment

Deploy [Pinner S3 Server](https://github.com/LumeWeb/s3-server) on a Vultr Cloud Compute instance via Packer snapshot with auto-update sidecar.

## What This Deploys

| Component | Description |
|-----------|-------------|
| **s3-server** | Object storage server (`ghcr.io/lumeweb/s3-server:latest`) on port **80** |
| **updater** | Sidecar container (`ghcr.io/lumeweb/s3-server-updater:latest`) that polls GHCR for new images every 6 hours |
| **s3-data** | Named volume mounted at `/data` for persistent storage |
| **s3-state** | Named volume mounted at `/state` for sidecar flag files |
| **ufw** | Firewall enabled (SSH + port 80) |
| **Systemd** | `s3-server.service` starts Docker Compose on boot |
| **Cloud-init** | Per-instance boot script removes SSH lockout, starts the service |

## Requirements

- **Vultr** account with Cloud Compute creation permissions
- Vultr API key (for Packer builds)
- Minimum plan: `vc2-1c-2gb` (1 vCPU, 2GB RAM) for builds and production
- Base image: Ubuntu 22.04

## Quick Start

### Option A: Deploy from Marketplace App

1. Go to the Vultr Marketplace and search for **Pinner S3 Server**
2. Click **Deploy**
3. Choose plan: `vc2-1c-2gb` minimum
4. Choose region
5. Click **Deploy Now**
6. SSH in; the MOTD displays access info and quick-start commands
7. Access the S3 API at `http://<server-ip>/`

Auto-update is ON by default. To disable:
```bash
touch /state/autoupdate.disabled
```

### Option B: Build the Snapshot with Packer

```bash
export VULTR_API_KEY="your-api-key"
cd /path/to/s3-cloud/deploy/vultr
make build
```

This creates a snapshot named `pinner-s3-vultr-<timestamp>` and writes `manifest.json` containing the snapshot ID. Create an instance from it:

```bash
SNAPSHOT_ID=$(jq -r '.builds[-1].artifact_id' manifest.json)
vultr-cli instance create \
  --region="ewr" \
  --plan="vc2-1c-2gb" \
  --snapshot="$SNAPSHOT_ID" \
  --label="s3-server" \
  --host="s3-server"
```

For standalone Docker Compose usage on an existing instance:
```bash
export DOCKER_GID=$(getent group docker | cut -d: -f3)
git clone https://github.com/LumeWeb/s3-cloud.git
cd s3-cloud
docker compose up -d
```

## CI/CD Pipeline

Two GitHub Actions workflows manage the release lifecycle:

| Workflow | Trigger | What it does |
|----------|---------|-------------|
| `packer-ci.yml` | PR to `develop` | `packer fmt -check`, `packer validate -syntax-only`, shellcheck, Python compile |
| `packer-release.yml` | Tag `v*` or manual | `make build` -> `make validate` -> `make submit` |

### Required GitHub Actions Secrets

| Secret | Purpose |
|--------|---------|
| `VULTR_API_KEY` | Packer builds, vultr-cli auth, API verification |
| `CI_BUILD_SSH_KEY` | Private SSH key (ed25519) for validation SSH access |

### SSH Key Setup

The validation step creates a temp instance and SSHes into it to run health checks. This requires:

1. **Generate a keypair** (if you don't have one):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/ci-build-key -N ""
   ```

2. **Add the public key to Vultr**: The Packer Vultr builder automatically manages SSH keys. For validation, the public key must be added to the instance via cloud-init user-data or the Vultr SSH key API.

3. **Add GitHub secrets**:
   - `CI_BUILD_SSH_KEY`: contents of `~/.ssh/ci-build-key` (private key, base64-encoded)
   - `VULTR_API_KEY`: your Vultr API key

## Release Process

### Automated (via tag)

1. Merge PR to `develop`
2. Tag: `git tag v1.0.0 && git push origin v1.0.0`
3. `packer-release.yml` runs: build snapshot -> validate instance -> submit
4. Monitor in GitHub Actions tab and Vultr Console

### Manual

```bash
export VULTR_API_KEY="your-key"

cd deploy/vultr

# Build, validate, and submit (dry-run by default)
make all

# Submit for real
make submit DRY_RUN=false
```

Or step-by-step:
```bash
make build       # Packer builds snapshot, writes manifest.json
make validate    # vultr-cli creates temp instance, runs health checks, destroys
make submit      # submit.py verifies snapshot, prints manual assignment instructions
```

## Marketplace Submission

Vultr does not expose a public API for assigning snapshots to marketplace apps. The `submit.py` script:

1. Verifies the snapshot exists via the Vultr API v2
2. Prints the snapshot ID and status
3. Prints step-by-step instructions for manual assignment in the Vultr Console

To assign manually after `make submit`:
1. Go to the Vultr Console -> Marketplace
2. Select your app -> Build App Image
3. Select the snapshot ID from the submit output
4. Click Build App Image
5. Go to Settings -> Make Public to submit for review

## Makefile Targets

| Target | What it does |
|--------|-------------|
| `make build` | `packer init` + `packer validate` + `packer build -force` |
| `make validate` | Create temp instance from snapshot, run health checks, destroy |
| `make submit` | Run `submit.py` (dry-run by default; `DRY_RUN=false` to verify and print instructions) |
| `make all` | build -> validate -> submit (fails fast on any step) |
| `make cleanup-snapshot` | Delete snapshot via vultr-cli (used after PR validation) |
| `make prune` | Delete old snapshots older than MAX_AGE_HOURS (default 24) |
| `make clean` | Remove `manifest.json` |

## Persistent Storage

Docker named volumes `s3-data` (`/data`) and `s3-state` (`/state`) persist on the instance's local disk. For additional storage, attach a Vultr Block Storage volume.

## Auto-Update

Auto-update is **ON by default**. The updater sidecar polls GHCR for new `:latest` image digests every 6 hours.

### Flag-File API

| File | Purpose |
|------|---------|
| `/state/autoupdate.enabled` | Present = auto-update ON |
| `/state/autoupdate.disabled` | Present = auto-update OFF (takes precedence) |
| `/state/update.trigger` | Force update check on next cycle |
| `/state/updater.log` | Append-only updater log |
| `/state/last-digest` | Last applied image digest |

### Disable Auto-Update

```bash
touch /state/autoupdate.disabled
```

### Force a Manual Update

```bash
touch /state/update.trigger
```

### View Updater Logs

```bash
cat /state/updater.log
```

## Files

| File | Purpose |
|------|---------|
| `template.pkr.hcl` | Packer template (Vultr builder, manifest post-processor) |
| `Makefile` | Build, validate, submit, cleanup, prune, all targets |
| `submit.py` | Snapshot verification and manual submission instructions |
| `shared/files/etc/update-motd.d/99-one-click` | MOTD shown on first SSH login - shared across vendors |
| `shared/files/var/lib/cloud/scripts/per-instance/001_onboot` | Cloud-init boot script - shared across vendors |
| `shared/scripts/014-ufw-s3.sh` | Firewall configuration (ufw) - shared across vendors |
| `shared/scripts/018-force-ssh-logout.sh` | SSH lockout during first-boot setup - shared across vendors |
| `scripts/900-cleanup.sh` | Image cleanup (logs, keys, disk zeroing, Vultr kernel, fstrim, machine-id) |
| `scripts/validate.sh` | Temp instance validation via vultr-cli + health checks |
| `scripts/prune-snapshots.py` | Prune old Vultr snapshots by prefix (used by CI cleanup / daily cron) |
| `scripts/prune-instances.py` | Prune old Vultr instances by prefix (used by daily cron) |
| `README.md` | This file |

## Shared Provisioner

The Packer template uses the shared provisioner at `packer/scripts/install-s3-server.sh` which handles:
- Docker Engine + docker-compose-plugin installation
- DOCKER_GID detection and `.env` file creation
- docker-compose.yml deployment to `/opt/s3-server/`
- systemd service unit creation with `EnvironmentFile`

## License

MIT. The S3 Server itself is licensed separately; see the [upstream repo](https://github.com/LumeWeb/s3-server).
