# s3-server Update Sidecar

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  Host                                                 │
│                                                       │
│  ┌─────────────┐               ┌──────────────────┐  │
│  │  s3-server   │   ← shared →  │  s3-updater      │  │
│  │  port 8080   │   /state      │  (this sidecar)  │  │
│  │              │               │                   │  │
│  │  /data  ✓    │               │  docker.sock rw ✓│  │
│  │  /state ✓    │               │  /state      ✓   │  │
│  │              │               │  compose.yml ro │  │
│  └─────────────┘               └──────────────────┘  │
│         NO SOCKET ACCESS                                │
└──────────────────────────────────────────────────────┘
```

The **s3-server** container runs the object storage service and never gets
access to the Docker socket. The **updater** sidecar is the *only* component
that talks to Docker - it polls GHCR for `:latest` digest changes and recreates
`s3-server` via `docker compose`.

No `os/exec`, `tini`, Watchtower, or Docker-in-Docker. The sidecar is ~170
lines of bash running `curl` + `docker` CLI.

## Flag-file API (shared `/state` volume)

The panel and the sidecar communicate through flag files on the shared
`/state` volume. This is the only cross-container channel - no HTTP API, no
socket path.

| File                         | Meaning                                                             |
|------------------------------|---------------------------------------------------------------------|
| `/state/autoupdate.enabled`  | Present => auto-update is ON (the default for compose deployments). |
| `/state/autoupdate.disabled` | Present => auto-update is OFF. Takes precedence over `.enabled`.     |
| `/state/update.trigger`      | Present => force a poll+update on the next cycle. Auto-removed.      |
| `/state/last-digest`         | Last-applied image digest (written by updater).                     |
| `/state/updater.log`          | Append-only log.                                                    |

Auto-update defaults to ON for the cloud / self-hosted Docker compose
deployment. If `autoupdate.disabled` exists it wins; if neither file exists the
updater keeps running, matching the "ON by default" policy.

## How updates work

1. Every `UPDATE_INTERVAL` seconds (default 21600 = 6 h) the sidecar fetches
   the GHCR v2 manifest for `ghcr.io/lumeweb/s3-server:latest` and reads the
   `Docker-Content-Digest` header.
2. If the digest differs from `/state/last-digest` (or the file is missing) it
   runs:
   ```
   docker compose -p s3-deployment pull s3-server
   docker compose -p s3-deployment up -d s3-server
   ```
   Old images for this repository are cleaned up (dangling images from other
   projects are left untouched).
3. On success the new digest is stamped to `/state/last-digest`.

## Manual / panel-triggered update

```
touch /state/update.trigger
```

The sidecar notices within one poll cycle (≤ `UPDATE_INTERVAL`), runs the
update pipeline, and removes the trigger file.

## Disabling auto-update

```
touch /state/autoupdate.disabled
```

The updater will keep running and logging but skip the digest-pull step.
Re-enable with `rm /state/autoupdate.disabled`.

## Build

```sh
docker build -t ghcr.io/lumeweb/s3-server-updater:latest \
  -f sidecar/Dockerfile.updater sidecar/
```

## Files

| Path                        | Purpose                                                    |
|-----------------------------|------------------------------------------------------------|
| `sidecar/updater.sh`        | The polling/update script (~170 lines bash).              |
| `sidecar/Dockerfile.updater`| Alpine + docker-cli + curl + jq; ENTRYPOINT is `updater.sh`. |

## Dependencies of the sidecar image

- `docker:29-cli` base (includes the Docker CLI, no daemon)
- `curl` for GHCR API calls
- `jq` for JSON parsing (GHCR token extraction)
- `bash` + `coreutils` (`date`, `tee`, `sed`, `tr`)

The compose file mounts the host's `/var/run/docker.sock` into the sidecar
(read-write; grants host root — accepted risk) so it can drive `docker compose`
on the host; s3-server never sees the socket.
