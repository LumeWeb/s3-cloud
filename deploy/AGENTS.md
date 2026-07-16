# deploy/AGENTS.md

Platform-agnostic guide for adding new cloud provider deployments to s3-cloud.

## Architecture

Each platform is a self-contained directory under `deploy/<vendor>/`. There is no shared code between platforms; each vendor has its own Packer template, Makefile, scripts, and API submission tooling. The only shared component is the provisioning script at `packer/scripts/install-s3-server.sh`, which every platform calls from its Packer template.

```
deploy/
├── AGENTS.md                  # This file (agnostic guide)
├── digitalocean/              # Reference implementation (has its own AGENTS.md)
└── <new-vendor>/              # New vendor (create its own AGENTS.md)
```

## Adding a New Platform

### 1. Create the directory structure

```bash
mkdir -p deploy/<vendor>/{scripts,files/var/lib/cloud/scripts/per-instance,files/etc/update-motd.d}
```

### 2. Packer template (`template.pkr.hcl`)

**Snapshot naming**: All snapshots must use the prefix `pinner-s3-<vendor>-` (e.g. `pinner-s3-do-{{timestamp}}`, `pinner-s3-linode-{{timestamp}}`). This makes it easy to identify and clean up images across vendors.

Required provisioner sequence (order matters):

1. **cloud-init wait**: `cloud-init status --wait` before any provisioning (VM may not have network or package repos ready)
2. **System updates**: Package update + upgrade with non-interactive flags to prevent prompts that hang the build
3. **File uploads**: `docker-compose.yml` to `/tmp/`, MOTD to `/etc/update-motd.d/99-one-click`, cloud-init boot script to `/var/lib/cloud/scripts/per-instance/001_onboot`
4. **Shared provisioner**: Run `../../packer/scripts/install-s3-server.sh` (handles Docker install, compose deployment, systemd service, DOCKER_GID detection)
Enable firewall (SSH + port 80). If using ufw with Docker, set FORWARD policy appropriately
6. **Application tag**: Write metadata to the vendor's application info location
7. **SSH lockout**: Force SSH logout during first-boot setup if the marketplace supports it
8. **Cleanup**: Clear logs, SSH keys, bash history, zero disk space, remove monitoring agents (most marketplaces reject images with monitoring agents installed)
9. **Manifest post-processor**: Output `manifest.json` with the snapshot/image ID for CI

### 3. Makefile

Must implement these targets:

```makefile
.PHONY: build validate submit cleanup-snapshot all clean

all: build validate submit

build:
	packer init .
	packer validate .
	packer build -force .

validate:
	# Vendor-specific: create temp VM from snapshot, run validation, destroy

submit:
	python3 submit.py --manifest $(MANIFEST) --dry-run=$(DRY_RUN) --version="$(VERSION)" --reason="$(REASON)"

cleanup-snapshot:
	# Delete the snapshot from vendor cloud (used after PR validation)

clean:
	rm -f $(MANIFEST)
```

Key conventions:
- `DRY_RUN` defaults to `true`; CI overrides with `DRY_RUN=false`
- `VERSION` and `REASON` are passed from the release workflow
- Use `bash ./scripts/validate.sh` (not `./scripts/validate.sh`); CI containers lose execute bits
- `cleanup-snapshot` reads the snapshot ID from `manifest.json` and deletes it via the vendor CLI

### 4. Validation script (`scripts/validate.sh`)

Creates a temp VM from the built snapshot/image, runs the vendor's validation tool, destroys it. Critical patterns:

- **SSH readiness loop**: New VMs take 30-60s to become SSH-accessible. Loop with 10s sleeps, max 12 attempts
- **Explicit SSH key path**: Use `ssh -i ~/.ssh/id_ed25519`, never rely on default key discovery
- **Cleanup on failure**: Always destroy the temp VM, even if validation fails (use `trap` or explicit cleanup before exit)
- **Remote script execution**: Download the vendor's validation script and pipe it over SSH: `ssh ... "bash -s" < <(curl -fsSL "$URL")`

### 5. Submission script (`submit.py`)

Thin Python script (~50-60 lines) that reads `manifest.json`, extracts the image ID, and calls the vendor's marketplace API. Use only stdlib (`urllib`, `json`, `argparse`). No external dependencies.

### 6. Cloud-init boot script (`files/var/lib/cloud/scripts/per-instance/001_onboot`)

Runs on every new VM instance from the snapshot. Responsibilities:

- Remove SSH lockout (if using force-ssh-logout)
- Start the s3-server systemd service
- Any first-boot initialization

### CI integration

Two workflows handle CI:

**`packer-ci.yml` (PR builds)**: Lint, build snapshot, validate, cleanup. Snapshots are ephemeral and deleted after validation. This enables real cloud builds on every PR without accumulating orphaned images. **Build jobs are gated**: only repo collaborators (write/admin/maintain) can trigger cloud builds from PRs. External contributors' PRs run lint only. Push events and manual dispatch bypass the check.

**`packer-release.yml` (release)**: Build snapshot, validate, submit to Vendor Portal. Build and submit are separate jobs connected via artifact (manifest.json). This means a build can succeed even if the marketplace listing is not ready to update.

To add a new vendor to CI:
- Add vendor detection logic to the lint job
- Add vendor-specific GitHub Actions secrets (API token, SSH key, etc.)
- The build/validate/cleanup/submit jobs are vendor-agnostic via the `VENDOR` env var

### 8. Vendor AGENTS.md

Create `deploy/<vendor>/AGENTS.md` documenting vendor-specific details: CLI tool quirks, API endpoints, validation script URLs, secret names, and pitfalls discovered during implementation. See `deploy/digitalocean/AGENTS.md` as the example.

## Common Pitfalls (Vendor-Agnostic)

### act (local CI testing)

- **Execute bits lost**: `act` copies files into containers without execute permissions. Use `bash ./script.sh` instead of `./script.sh` in Makefiles
- **Multi-line secrets**: `.secrets` files use `KEY=VALUE` per line. Multi-line values (SSH keys) must be base64-encoded: `KEY=$(base64 -w0 keyfile)`. The workflow step must then decode: `echo "$KEY" | base64 -d > ~/.ssh/id_ed25519`
- **`--secret-file`** not `--secretfile` (act flag name)
- **`--insecure-secrets`** required to prevent act from masking values inline

### Packer

- **cloud-init first**: Always wait for `cloud-init status --wait` before any provisioning
- **Force confdef**: Use `--force-confdef --force-confold` on apt upgrades to prevent interactive prompts that hang the build
- **Build on smallest VM**: Use the smallest available instance size for the build. This ensures compatibility with the widest range of customer plan sizes
- **Zero disk space**: Run `dd if=/dev/zero of=/zerofile` as the final cleanup step. This reduces snapshot size and is required by some marketplaces

### GitHub Actions Security

- **Never interpolate `github.event.inputs.*` in `run:` blocks**: use the `env:` block and reference shell variables to prevent script injection
- **Always quote shell variables**: `"$VAR"`, not `$VAR`

## Shared Provisioner

The script at `packer/scripts/install-s3-server.sh` is called by every platform's Packer template. It handles:

- Docker Engine + docker-compose-plugin installation via `get.docker.com`
- `DOCKER_GID` detection from host (`getent group docker`) and `.env` file creation
- `docker-compose.yml` deployment to `/opt/s3-server/`
- systemd service unit creation with `EnvironmentFile`
- Auto-update enabled by default (sidecar creates the flag on startup)

This script works as-is for any Debian/Ubuntu-based image. For non-Debian images (e.g. RHEL-based), create a platform-specific variant.

## Verification Checklist

Before opening a PR for a new platform:

- [ ] `shellcheck` passes on all `.sh` files
- [ ] `packer validate .` passes
- [ ] `packer build -force .` creates a snapshot successfully
- [ ] `make build` + `make validate` passes end-to-end
- [ ] `make submit DRY_RUN=true` prints the correct API request
- [ ] Temp VM is destroyed after validation (no leftover resources)
- [ ] `deploy/<vendor>/AGENTS.md` documents vendor-specific details
- [ ] `deploy/<vendor>/README.md` documents all required secrets and setup steps
- [ ] CI workflow triggers correctly on tags and manual dispatch
