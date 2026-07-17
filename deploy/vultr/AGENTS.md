# deploy/vultr/AGENTS.md

Vultr Marketplace deployment specifics. See `deploy/AGENTS.md` for the platform-agnostic guide.

## Vultr CLI Tools

### vultr-cli

- **Install**: Download from https://github.com/vultr/vultr-cli (releases page). In CI, resolve the latest asset URL via GitHub API with `Authorization: Bearer ${{ secrets.GITHUB_TOKEN }}` to avoid rate limits.
- **Auth**: `vultr-cli` reads `VULTR_API_KEY` env var. Get from https://my.vultr.com/settings/#settingsapi
- **Output**: `--output=json` gives machine-parseable JSON. Always pair with `jq`.
- **Config file bug (v3.x)**: `vultr-cli` prints `Error reading in config file` to stdout if `~/.vultr-cli.yaml` doesn't exist, corrupting JSON output. Always `touch ~/.vultr-cli.yaml` before any CLI invocation in CI/scripts.
- **Instance creation**: `vultr-cli instance create --region --plan --snapshot --label --host --ssh-key`
- **SSH key injection**: Packer cleans SSH keys from the image during build. Validation instances must pass `--ssh-key` with a key ID uploaded via `vultr-cli ssh-key create`. The CI workflow uploads the build key as `ci-build-key` and passes the ID to `validate.sh` via `VULTR_SSH_KEY_ID` env var.
- **Instance IPs**: `vultr-cli instance get <id> --output=json | jq -r '.instance.main_ip'`
- **Snapshot deletion**: `vultr-cli snapshot delete <id>`
- **No marketplace submit API**: Vultr does not expose a public API for assigning snapshots to marketplace apps. Submission is manual via the Vultr Console.

### Vultr API v2

- **Base URL**: `https://api.vultr.com/v2`
- **Auth**: Bearer token (`VULTR_API_KEY`)
- **Snapshots**: `GET /snapshots`, `GET /snapshots/{id}`, `DELETE /snapshots/{id}`
- **Pagination**: `meta.pagination.links.next` contains the full URL for the next page
- **Timestamps**: ISO 8601 with timezone offset (e.g. `2026-07-16T12:34:56+00:00`)

### Marketplace Submission

- **No API for assignment**: Unlike DigitalOcean's Vendor Portal API, Vultr does not expose a public API for assigning snapshots to marketplace apps.
- **Manual process**: `submit.py` verifies the snapshot exists via the API, then prints instructions for manual assignment in the Vultr Console:
    1. Vultr Console -> Marketplace
    2. Select app -> Build App Image
    3. Select snapshot by ID
    4. Click Build App Image
    5. Settings -> Make Public to submit for review

## Vultr Marketplace Requirements

### Required Scripts (run as final Packer provisioners)

| Script | Source | Purpose |
|--------|--------|---------|
| `shared/scripts/014-ufw-s3.sh` | Shared | Enable ufw firewall (SSH + port 80, Docker FORWARD policy) |
| `shared/scripts/018-force-ssh-logout.sh` | Shared | Block SSH until `001_onboot` completes first-boot setup |
| `scripts/900-cleanup.sh` | Vultr-specific | Clear logs, SSH keys, bash history, zero disk, Vultr kernel option, fstrim, machine-id, random-seed |

### Validation

Vultr does not provide a standard marketplace validation script like DO's `99-img-check.sh`. The `validate.sh` script creates a temp instance from the snapshot and performs health checks:

- SSH connectivity (cloud-init completed, SSH lockout removed)
- Detects ForceCommand "Please wait" message as "SSH up but cloud-init still running"
- `s3-server.service` is active
- Docker containers are running
- HTTP healthz endpoint responds with 200

**SSH wait**: 600s (60 attempts × 10s). Vultr instances take significantly longer to boot than DO droplets.

**Healthcheck**: The Docker healthcheck in `docker-compose.yml` must use `wget -q -O /dev/null` (GET), NOT `wget --spider` (HEAD). The `/_panel/healthz` endpoint is registered as GET-only in Echo, so HEAD returns 405 Method Not Allowed.

### Marketplace Compliance

Based on Vultr's marketplace documentation:

- Supported OS: Ubuntu 22.04 (os_id 1743)
- cloud-init installed
- No root password set
- No SSH keys in `/root/.ssh/`
- Root bash history cleared
- No vendor monitoring agents installed
- No pending security updates
- Firewall configured
- Logs cleared

## Required Secrets

| Secret | Purpose |
|--------|---------|
| `VULTR_API_KEY` | Packer builds, vultr-cli auth, API verification |
| `CI_BUILD_SSH_KEY` | Private SSH key (ed25519, base64-encoded). Written to `~/.ssh/id_ed25519` on the runner. Public key uploaded to Vultr as `ci-build-key` for validation instance SSH access. |

## Vultr-Specific Configuration

### Packer Builder

| Field | Value | Notes |
|-------|-------|-------|
| `os_id` | `1743` | Ubuntu 22.04 x64 |
| `plan_id` | `vc2-1c-2gb` | 1 vCPU, 2GB RAM. Required for Docker provisioning. |
| `region_id` | `ewr` | New Jersey (default). Can be overridden. |
| `ssh_username` | `root` | Vultr provides root access by default. |
| `state_timeout` | `25m` | Vultr snapshot creation can take up to 20 minutes. |

### Differences from DigitalOcean

| Aspect | DigitalOcean | Vultr |
|--------|-------------|-------|
| Vendor agent purge | Required (`droplet-agent`) | Not needed (Vultr does not pre-install agents) |
| SSH key management | Must upload public key, reference fingerprint | Must upload public key as `ci-build-key`, pass `--ssh-key` on instance create |
| Marketplace submit API | Vendor Portal API (PATCH) | No public API; manual via Console |
| Validation script | DO's `99-img-check.sh` | Custom health checks (service + HTTP) |
| Application metadata | `/var/lib/digitalocean/application.info` | `/var/lib/s3-server/application.info` |
| Snapshot naming | `pinner-s3-do-<timestamp>` | `pinner-s3-vultr-<timestamp>` |
| Build plan | `s-1vcpu-1gb` | `vc2-1c-2gb` |
| API pagination | `links.pages.next` | `meta.pagination.links.next` |
| CI workflow | `packer-ci-digitalocean.yml` | `packer-ci-vultr.yml` |
| Release workflow | `packer-release-digitalocean.yml` | `packer-release-vultr.yml` |

## Vultr-Specific Pitfalls

- **No vendor agent**: Vultr base OS images do not ship with a monitoring agent, so the cleanup script does not need an agent purge step (unlike DO's `droplet-agent`).
- **Snapshot creation time**: Vultr snapshots can take 10-20 minutes. The Packer `state_timeout` is set to 25 minutes to accommodate this. Packer blocks until the snapshot completes; no additional wait is needed in `validate.sh`.
- **Prune scripts**: Split into `prune-snapshots.py` and `prune-instances.py`. Each requires `--prefix` (no default). Never combine snapshot and instance deletion.
- **No marketplace submit API**: The `submit.py` script verifies the snapshot exists but cannot programmatically assign it to a marketplace app. This must be done manually.
- **OS ID**: Vultr uses numeric OS IDs. `1743` = Ubuntu 22.04 x64. These can change; verify at https://www.vultr.com/api/#tag/os
- **Region IDs**: Short string codes like `ewr`, `lax`, `ord`. Different from DO's `nyc3`-style names.
