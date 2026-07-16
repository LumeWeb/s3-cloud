# Pinner S3 Server: DigitalOcean Marketplace Deployment

Deploy [Pinner S3 Server](https://github.com/LumeWeb/s3-server) on a DigitalOcean Droplet via Packer snapshot with auto-update sidecar.

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

- **DigitalOcean** account with Droplet creation permissions
- DigitalOcean API token (for Packer builds)
- Minimum Droplet size: `s-1vcpu-1gb` (build size); `s-1vcpu-2gb` recommended for production
- Base image: Ubuntu 22.04

## Quick Start

### Option A: Deploy from Marketplace 1-Click App

1. Go to the DigitalOcean Marketplace and search for **Pinner S3 Server**
2. Click **Create Pinner S3 Server Droplet**
3. Choose plan: `s-1vcpu-2gb` minimum recommended
4. Choose datacenter region
5. Click **Create Droplet**
6. SSH in; the MOTD displays access info and quick-start commands
7. Access the S3 API at `http://<droplet-ip>/`

Auto-update is ON by default. To disable:
```bash
touch /state/autoupdate.disabled
```

### Option B: Build the Snapshot with Packer

```bash
export DIGITALOCEAN_API_TOKEN="your-api-token"
cd /path/to/s3-cloud/deploy/digitalocean
make build
```

This creates a snapshot named `s3-server-<timestamp>` and writes `manifest.json` containing the snapshot ID. Create a Droplet from it:

```bash
doctl compute droplet create s3-server \
  --image s3-server-<timestamp> \
  --size s-1vcpu-2gb \
  --region nyc3
```

For standalone Docker Compose usage on an existing Droplet:

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
| `packer-release.yml` | Tag `v*` or manual | `make build` → `make validate` → `make submit` |

### Required GitHub Actions Secrets

| Secret | Purpose |
|--------|---------|
| `DIGITALOCEAN_API_TOKEN` | Packer builds, doctl auth, Vendor API auth |
| `CI_BUILD_SSH_KEY` | Private SSH key (ed25519) for `doctl compute ssh` during validation |
| `DO_SSH_KEY_ID` | Fingerprint of the public key registered in DO (must match `CI_BUILD_SSH_KEY`) |
| `DO_VENDOR_APP_ID` | Marketplace app ID (from Vendor Portal URL) |

### SSH Key Setup

The validation step creates a temp Droplet and SSHes into it to run DO's `99-img-check.sh`. This requires:

1. **Generate a keypair** (if you don't have one):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/ci-build-key -N ""
   ```

2. **Upload the public key to DigitalOcean**:
   ```bash
   doctl compute ssh-key create ci-build-key \
     --public-key "$(cat ~/.ssh/ci-build-key.pub)"
   # Note the fingerprint from the output
   ```

3. **Add GitHub secrets**:
   - `CI_BUILD_SSH_KEY`: contents of `~/.ssh/ci-build-key` (private key)
   - `DO_SSH_KEY_ID`: the fingerprint from step 2

The workflow writes `CI_BUILD_SSH_KEY` to `~/.ssh/id_ed25519` on the runner, then `doctl compute ssh` uses it to connect to the temp validation Droplet.

## Release Process

### Automated (via tag)

1. Merge PR to `develop`
2. Tag: `git tag v1.0.0 && git push origin v1.0.0`
3. `packer-release.yml` runs: build snapshot → validate with `img-check.sh` → submit to Vendor API
4. Monitor in GitHub Actions tab and DO Vendor Portal

### Manual

```bash
export DIGITALOCEAN_API_TOKEN="your-token"
export DO_VENDOR_APP_ID="your-app-id"
export DO_SSH_KEY_ID="your-ssh-key-fingerprint"

cd deploy/digitalocean

# Build, validate, and submit (dry-run by default)
make all

# Submit for real
make submit DRY_RUN=false
```

Or step-by-step:
```bash
make build       # Packer builds snapshot, writes manifest.json
make validate    # doctl creates temp Droplet, runs img-check.sh, destroys
make submit      # submit.py reads manifest, PATCHes Vendor API
```

## Makefile Targets

| Target | What it does |
|--------|-------------|
| `make build` | `packer init` + `packer validate` + `packer build -force` |
| `make validate` | Create temp Droplet from snapshot, run `99-img-check.sh`, destroy |
| `make submit` | Run `submit.py` (dry-run by default; `DRY_RUN=false` to submit) |
| `make all` | build → validate → submit (fails fast on any step) |
| `make clean` | Remove `manifest.json` |

## Marketplace Validation

The Packer template includes DO's required marketplace scripts as final provisioners:

| Script | Purpose |
|--------|---------|
| `scripts/014-ufw-s3.sh` | Enables ufw firewall (SSH + port 80, Docker FORWARD policy) |
| `scripts/020-application-tag.sh` | Writes app metadata to `/var/lib/digitalocean/application.info` |
| `scripts/018-force-ssh-logout.sh` | Blocks SSH until `001_onboot` completes first-boot setup |
| `scripts/900-cleanup.sh` | Clears logs, SSH keys, bash history, zeros disk, purges droplet-agent |

The `make validate` target runs DO's `99-img-check.sh` on a temp Droplet created from the snapshot. This catches validation failures before submitting to the Vendor Portal.

## Adding New Vendors

Each vendor is a self-contained directory under `deploy/`. To add a new cloud provider:

1. Create `deploy/<vendor>/` with the same structure:
   - `Makefile` with `build`, `validate`, `submit`, `all` targets
   - `template.pkr.hcl` (Packer template with that cloud's builder)
   - `submit.py` or equivalent for the vendor's marketplace API
   - `scripts/` for vendor-specific validation/provisioning
2. Add vendor-specific GitHub Actions secrets
3. Update `packer-release.yml` to support `--vendor <name>` input

## Persistent Storage

Docker named volumes `s3-data` (`/data`) and `s3-state` (`/state`) persist on the Droplet's local disk. For additional storage, attach a DigitalOcean Block Storage volume.

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
| `template.pkr.hcl` | Packer template (DO builder, manifest post-processor) |
| `Makefile` | Build, validate, submit, all targets |
| `submit.py` | Vendor Portal API submission (reads manifest.json) |
| `files/etc/update-motd.d/99-one-click` | MOTD shown on first SSH login |
| `files/var/lib/cloud/scripts/per-instance/001_onboot` | Cloud-init per-instance boot script |
| `scripts/014-ufw-s3.sh` | Firewall configuration (ufw) |
| `scripts/020-application-tag.sh` | Application metadata tag |
| `scripts/018-force-ssh-logout.sh` | SSH lockout during first-boot setup |
| `scripts/900-cleanup.sh` | Image cleanup (logs, keys, disk zeroing) |
| `scripts/validate.sh` | Temp Droplet validation via doctl + img-check |
| `MARKETPLACE_README.md` | Marketplace listing text (static, no version) |
| `README.md` | This file |

## Shared Provisioner

The Packer template uses the shared provisioner at `packer/scripts/install-s3-server.sh` which handles:
- Docker Engine + docker-compose-plugin installation
- DOCKER_GID detection and `.env` file creation
- docker-compose.yml deployment to `/opt/s3-server/`
- systemd service unit creation with `EnvironmentFile`

## License

MIT. The S3 Server itself is licensed separately; see the [upstream repo](https://github.com/LumeWeb/s3-server).
