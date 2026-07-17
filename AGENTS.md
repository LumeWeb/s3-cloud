# AGENTS.md

## Project

s3-cloud: multi-platform deployment configs for [s3-server](https://github.com/LumeWeb/s3-server) - Pinner.xyz S3 Server: private, zero-knowledge self-hosted S3-compatible object storage. Single Docker image deployed across multiple targets.

## Key Facts

- **Docker image**: `ghcr.io/lumeweb/s3-server:latest` (amd64 + arm64)
- **Updater image**: `ghcr.io/lumeweb/s3-server-updater:latest`
- **S3 API port**: 80 (host), 8080 (container internal)
- **Data volume**: `/data` (DB + upload staging)
- **State volume**: `/state` (sidecar flag files)
- **GitHub org**: `lumeweb` (used in all URLs, GHCR paths, Go module paths)
- **Brand**: Pinner.xyz (used in display names, descriptions, taglines)

## Layout

```
s3-cloud/
├── docker-compose.yml          # Standalone deployment (s3-server + updater sidecar)
├── deploy/                     # Per-platform configs (added incrementally)
│   ├── AGENTS.md               # Platform-agnostic deployment guide
│   ├── shared/                 # Provider-agnostic scripts and files
│   ├── digitalocean/           # DO Marketplace deployment
│   └── vultr/                  # Vultr Marketplace deployment
├── packer/
│   └── scripts/
│       └── install-s3-server.sh  # Shared VM provisioning script
├── sidecar/
│   ├── Dockerfile.updater      # Sidecar container image
│   └── updater.sh              # Update script (~170 lines bash)
├── docs/
│   └── platform-support.md     # Platform support matrix
└── .github/workflows/
    ├── packer-ci.yml           # CI dispatcher: detect vendors → gh workflow run per-vendor
    ├── packer-ci-digitalocean.yml  # CI: DO build + validate + cleanup (ephemeral)
    ├── packer-ci-vultr.yml     # CI: Vultr build + validate + cleanup (ephemeral)
    ├── packer-release.yml      # Release dispatcher: resolve vendors → gh workflow run per-vendor
    ├── packer-release-digitalocean.yml  # Release: DO build + validate + submit
    ├── packer-release-vultr.yml    # Release: Vultr build + validate + submit
    ├── prune-resources.yml     # Daily cron: prune orphaned snapshots + instances
    └── docker-publish.yml      # Sidecar multi-arch CI build
```

## Healthcheck

The Docker healthcheck in `docker-compose.yml` must use `wget -q -O /dev/null` (GET), NOT `wget --spider` (HEAD). The `/_panel/healthz` endpoint in s3-server is registered as GET-only in Echo, so HEAD returns 405 Method Not Allowed and the container is marked unhealthy.

## Prune Scripts

Each vendor has two separate prune scripts: `prune-snapshots.py` and `prune-instances.py`. Each requires `--prefix` (no default). Never combine snapshot and instance deletion in a single script — this was the source of multiple CI bugs. Instance names don't contain PR numbers, so instance pruning uses vendor-wide prefix + age filtering.

## Sidecar Flag-File API

Files in `/state/` volume, shared between s3-server panel and sidecar:

| File | Meaning |
|---|---|
| `/state/autoupdate.enabled` | Present = auto-update ON (default for VM deployments) |
| `/state/autoupdate.disabled` | Present = auto-update OFF (takes precedence over .enabled) |
| `/state/update.trigger` | Present = force update on next poll (one-shot, consumed) |
| `/state/last-digest` | Last applied image digest |
| `/state/updater.log` | Append-only log |

The sidecar polls GHCR `:latest` every 6 hours. The sleep loop checks for `/state/update.trigger` every 10 seconds, so manual triggers are responsive.

## Conventions

- **Branding**: Use "Pinner.xyz" for display names and descriptions.
- **GHCR/GitHub paths**: Stay as `lumeweb` / `LumeWeb` / `ghcr.io/lumeweb`.
- **Commits**: Conventional format (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`).
- **Secrets**: S3 access keys are passed via environment variables or cloud user-data, never hardcoded.

## Testing and Validation

- **Shell scripts**: `shellcheck` must pass clean. `bash -n` for syntax.
- **JSON files**: Validate with `python3 -c "import json; json.load(open('file'))"`.
- **YAML files**: Ensure they parse (docker compose config, or python yaml).

## License

MIT
