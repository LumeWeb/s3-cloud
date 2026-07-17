# deploy/AGENTS.md

Platform-agnostic guide for adding new cloud provider deployments to s3-cloud.

## Architecture

Each platform is a self-contained directory under `deploy/<vendor>/`. There is no shared code between platforms; each vendor has its own Packer template, Makefile, scripts, and API submission tooling. The only shared component is the provisioning script at `packer/scripts/install-s3-server.sh`, which every platform calls from its Packer template.

```
deploy/
├── AGENTS.md                  # This file (agnostic guide)
├── shared/                    # Provider-agnostic scripts and files shared across vendors
│   ├── MARKETPLACE_LISTING.md # Shared marketplace listing copy (vendor-agnostic)
│   ├── scripts/
│   │ ├── lib/
│   │ │   └── compliance-checks.sh  # Shared marketplace compliance check functions
│   │ ├── 014-ufw-s3.sh      # Firewall config (ufw: SSH + port 80)
│   │ └── 018-force-ssh-logout.sh  # SSH lockout during first-boot setup
│   └── files/
│       ├── etc/update-motd.d/99-one-click  # MOTD for SSH login
│       └── var/lib/cloud/scripts/per-instance/001_onboot  # Cloud-init boot script
├── digitalocean/              # Reference implementation (has its own AGENTS.md)
├── vultr/                     # Vultr Marketplace deployment (has its own AGENTS.md)
└── <new-vendor>/              # New vendor (create its own AGENTS.md)
```

### Shared Scripts

The `deploy/shared/` directory contains scripts and files that are identical across all vendors. Each Packer template references these via `${path.root}/../shared/scripts/...` (for shell provisioners) or `${path.root}/../shared/files/...` (for file uploads).

| Shared File | Purpose |
|-------------|---------|
| `MARKETPLACE_LISTING.md` | Shared marketplace listing copy (vendor-agnostic reference for manual submission) |
| `scripts/lib/compliance-checks.sh` | Shared marketplace compliance check functions (sourced by validate.sh) |
| `scripts/014-ufw-s3.sh` | Firewall config (ufw: SSH + port 80, Docker FORWARD policy) |
| `scripts/018-force-ssh-logout.sh` | SSH lockout until first-boot setup completes |
| `files/etc/update-motd.d/99-one-click` | MOTD shown on first SSH login |
| `files/var/lib/cloud/scripts/per-instance/001_onboot` | Cloud-init boot script (SSH unlock, Docker wait, service start) |

Scripts that have vendor-specific differences (e.g. `020-application-tag.sh`, `900-cleanup.sh`) remain in each vendor's `scripts/` directory.

## Adding a New Platform

### 1. Create the directory structure

```bash
mkdir -p deploy/<vendor>/{scripts,files/var/lib/cloud/scripts/per-instance,files/etc/update-motd.d}
```

### 2. Packer template (`template.pkr.hcl`)

**Snapshot naming**: Snapshots use the prefix `pinner-s3-<vendor>-` with a suffix that distinguishes build type. See [Snapshot Taxonomy](#snapshot-taxonomy) below for the full naming convention.

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
.PHONY: build validate submit cleanup-snapshot prune prune-snapshots prune-instances all clean

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

prune: prune-snapshots prune-instances

prune-snapshots:
	python3 scripts/prune-snapshots.py $$ARGS

prune-instances:
	python3 scripts/prune-instances.py $$ARGS

clean:
	rm -f $(MANIFEST)
```

Key conventions:
- `DRY_RUN` defaults to `true`; CI overrides with `DRY_RUN=false`
- `VERSION` and `REASON` are passed from the release workflow
- Use `bash ./scripts/validate.sh` (not `./scripts/validate.sh`); CI containers lose execute bits
- `cleanup-snapshot` reads the snapshot ID from `manifest.json` and deletes it via the vendor CLI
- `prune-snapshots` and `prune-instances` are separate scripts (one resource type each). Each requires `--prefix` (no default) to prevent accidental deletion of non-CI resources. Never combine snapshot and instance deletion in a single script call.

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

### Snapshot Taxonomy

Snapshot names encode their purpose so CI cleanup and daily prune can target the right ones without touching release images.

| Pattern | Build Type | Created By | Cleanup |
|---------|-----------|------------|---------|
| `pinner-s3-<vendor>-pr-<number>-<timestamp>` | PR build | `packer-ci.yml` on PR open/sync | PR close + daily prune (24h) |
| `pinner-s3-<vendor>-ci-<timestamp>` | Develop-push build | `packer-ci.yml` on push to develop | Inline cleanup + daily prune (24h) |
| `pinner-s3-<vendor>-<timestamp>` | Release build | `packer-release.yml` on tag/manual | **Never auto-pruned** |

### Protection Mechanisms

- **DigitalOcean**: Release snapshots are protected by querying the Vendor Portal API (`get_marketplace_image_id()`). The prune script skips any snapshot whose ID appears in the marketplace image set. Unlinked release snapshots (submit failed, pending review) are not protected, so the daily prune uses `--prefix pinner-s3-do-pr-` and `--prefix pinner-s3-do-ci-` to scope deletion to CI builds only.
- **Vultr**: No marketplace-link API exists. Release snapshots are protected by prefix separation only -- the daily prune targets `-pr-` and `-ci-` suffixes, never the bare `pinner-s3-vultr-` prefix. Manual snapshot-to-app assignment is done in the Vultr Console.

### CI Cleanup Flow

1. **PR open/sync**: Build snapshot with `-pr-<number>-` prefix. No cleanup (snapshot kept for validation).
2. **PR close**: `packer-ci.yml` cleanup job deletes all `pinner-s3-<vendor>-pr-<number>-*` snapshots via `prune-snapshots.py --prefix pinner-s3-<vendor>-pr-<number>-`.
3. **Push to develop/manual dispatch**: Build with `-ci-` or `-manual-` prefix. Inline cleanup deletes the specific snapshot via manifest after validation.
4. **Daily cron** (`prune-resources.yml`): Four passes per vendor — `prune-snapshots.py` for `-pr-` and `-ci-` prefixes, `prune-instances.py` for vendor-wide instance prefix. All with 24h max age. Instance names don't contain PR numbers, so instance pruning uses vendor-wide prefix + age filtering (never PR-scoped).
5. **Release**: Build with bare prefix. Submit to marketplace. Never pruned.

## CI Architecture

CI and release use a **dispatch-based fan-out** architecture. Each vendor has its own self-contained workflow — no matrix, no cross-vendor gating, no aggregate result checks.

### CI (PR builds)

**`packer-ci.yml`** is a thin dispatcher:
1. Detects which `deploy/<vendor>/` directories changed (additive: shared files trigger all vendors)
2. Checks collaborator permissions (gates cloud spend)
3. Runs lint (informational, does not block builds)
4. Dispatches per-vendor CI workflows via `gh workflow run`

Each per-vendor CI workflow (`packer-ci-<vendor>.yml`) runs independently:
- `build` → `validate` → `cleanup on failure` (inline, no separate cleanup job)
- PR close triggers cleanup mode (delete all snapshots matching `pr-<number>-` prefix)
- Push to develop triggers inline cleanup (ephemeral, `-ci-` prefix)

### Release (marketplace submission)

**`packer-release.yml`** is a thin dispatcher:
1. Resolves target vendors from input or tag
2. Dispatches per-vendor release workflows via `gh workflow run`

Each per-vendor release workflow (`packer-release-<vendor>.yml`) runs independently:
- `build` → `validate` → `submit` (all in one job, submit is the last step — no gating needed)
- On validation failure, cleans up the snapshot inline
- Release snapshots use bare prefix `pinner-s3-<vendor>-<timestamp>` and are never auto-pruned

### Shared Setup

Each per-vendor workflow inlines its own setup steps (checkout, SSH key, CLI install, Packer). This keeps each workflow fully self-contained — no cross-workflow dependencies for setup. Setup steps are duplicated across CI and release workflows for the same vendor, which is intentional (DRY is less important than workflow independence here).

### Adding a New Vendor to CI/Release

1. Add the vendor to the `detect-vendors` job's detection logic in `packer-ci.yml`
2. Add the vendor to the `resolve-vendors` job's vendor list in `packer-release.yml`
3. Create `packer-ci-<vendor>.yml` (copy from an existing vendor's CI workflow)
4. Create `packer-release-<vendor>.yml` (copy from an existing vendor's release workflow)
5. Add a `dispatch-<vendor>` job to both dispatchers using `gh workflow run`
6. Add vendor-specific GitHub Actions secrets

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
