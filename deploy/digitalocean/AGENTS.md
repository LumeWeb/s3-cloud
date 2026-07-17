# deploy/digitalocean/AGENTS.md

DigitalOcean Marketplace deployment specifics. See `deploy/AGENTS.md` for the platform-agnostic guide.

## DO CLI Tools

### doctl

- **No vendor portal support**: `doctl` has no marketplace submit/list subcommands. Marketplace submission requires raw HTTP calls via `submit.py`
- **Auth**: `doctl auth init -t <token>`. Token is read from `DIGITALOCEAN_API_TOKEN` env var
- **IP extraction**: Use `doctl compute droplet get <id> --format PublicIPv4 --no-header`. The `--template` field names change across doctl versions and are fragile
- **SSH auth**: `doctl compute ssh` looks for `~/.ssh/id_rsa` by default. Use direct `ssh -i ~/.ssh/id_ed25519` for explicit key control

### Vendor Portal API

- **Endpoint**: `PATCH https://api.digitalocean.com/api/v1/vendor-portal/apps/<app_id>`
- **Auth**: Bearer token (`DIGITALOCEAN_API_TOKEN`)
- **Body**: `{"imageId": <int>, "reasonForUpdate": "..."}`
- **Limitations**: Apps in "pending" or "in review" state return 400. Cannot self-publish; every image goes through DO's manual review via the Vendor Portal.

## DO Marketplace Requirements

### Required Scripts (run as final Packer provisioners)

| Script | Source | Purpose |
|--------|--------|---------|
| `shared/scripts/014-ufw-s3.sh` | Shared | Enable ufw firewall (SSH + port 80, Docker FORWARD policy) |
| `scripts/020-application-tag.sh` | DO-specific | Write app metadata to `/var/lib/digitalocean/application.info` |
| `shared/scripts/018-force-ssh-logout.sh` | Shared | Block SSH until `001_onboot` completes first-boot setup |
| `scripts/900-cleanup.sh` | DO-specific | Clear logs, SSH keys, bash history, zero disk, purge `droplet-agent` |

### Validation Tool

DO's `99-img-check.sh` checks:
- Supported OS (Ubuntu 20.04/22.04/24.04, Debian, CentOS, Rocky, AlmaLinux)
- cloud-init installed
- Firewall active (ufw/firewalld)
- No pending security updates
- Logs cleared from `/var/log`
- No root password or SSH keys
- No DigitalOcean Monitoring agent (`droplet-agent`)
- No MongoDB

**URL**: `https://raw.githubusercontent.com/digitalocean/marketplace-partners/master/scripts/99-img-check.sh`

Note: the repo's default branch is `master`, not `main`; using `main` returns 404.

### Marketplace Compliance (FAIL = rejection)

- Supported OS and version
- cloud-init installed
- No root password set
- No SSH keys in `/root/.ssh/`
- Root bash history cleared
- No `droplet-agent` installed
- No pending security updates
- Firewall configured

## Required Secrets

| Secret | Purpose |
|--------|---------|
| `DIGITALOCEAN_API_TOKEN` | Packer builds, doctl auth, Vendor API auth |
| `CI_BUILD_SSH_KEY` | Private SSH key (ed25519, base64-encoded for multi-line compatibility). Written to `~/.ssh/id_ed25519` on the runner |
| `DO_SSH_KEY_ID` | Fingerprint of the public key registered in DO (must match `CI_BUILD_SSH_KEY`) |
| `DO_VENDOR_APP_ID` | Marketplace app ID (from Vendor Portal URL) |

## DO-Specific Pitfalls

- **`droplet-agent` purge**: DO base images ship with the droplet-agent pre-installed. The cleanup script must `apt-get purge droplet-agent` or `99-img-check.sh` will fail. The purge leaves stale systemd unit files; warnings are harmless.
- **Snapshot naming**: Packer names snapshots as `pinner-s3-do-<timestamp>`. All vendors use the `pinner-s3-<vendor>-` prefix. DO doesn't charge for snapshots in the region they were created.
- **Cleanup**: PR CI builds (`packer-ci-digitalocean.yml`) clean up snapshots inline on failure and on PR close. Release builds (`packer-release-digitalocean.yml`) persist the snapshot for marketplace submission. Prune scripts are split: `prune-snapshots.py` (snapshots only, `--prefix` required) and `prune-instances.py` (droplets only, `--prefix` required). Never combine.
- **Build on `s-1vcpu-1gb`**: DO recommends the smallest droplet size for builds to ensure widest plan compatibility for end users.
- **Base image**: Currently `ubuntu-22-04-x64`. DO now recommends `ubuntu-24-04-x64` for new marketplace listings.
