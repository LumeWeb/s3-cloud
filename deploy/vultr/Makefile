.PHONY: build validate submit cleanup-snapshot prune prune-snapshots prune-instances all clean

TEMPLATE := template.pkr.hcl
MANIFEST := manifest.json
# Set DRY_RUN=true to print the API call without sending it
DRY_RUN  ?= true
# Version and reason passed from CI or manual invocation
VERSION  ?=
REASON   ?= Automated release
# Snapshot prefix: defaults to pinner-s3-vultr- for releases.
# CI sets SNAPSHOT_PREFIX=pinner-s3-vultr-pr-<number>- for PR builds.
SNAPSHOT_PREFIX ?= pinner-s3-vultr-

# Build: create snapshot in vendor cloud. Does NOT submit to marketplace.
all: build validate submit

build:
	packer init .
	packer validate .
	packer build -force -var "snapshot_prefix=$(SNAPSHOT_PREFIX)" .

# Validate: create temp VM from snapshot, run health checks, destroy temp VM.
validate:
	@command -v vultr-cli >/dev/null 2>&1 || { echo "Error: vultr-cli is required for validation"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "Error: jq is required for validation"; exit 1; }
	bash ./scripts/validate.sh $(MANIFEST)

# Submit: push snapshot to vendor marketplace. Vultr has no public API
# for assigning snapshots to marketplace apps, so this prints the snapshot
# ID and instructions for manual assignment in the Vultr Console.
submit:
	python3 submit.py --manifest $(MANIFEST) --dry-run=$(DRY_RUN) --version="$(VERSION)" --reason="$(REASON)"

# Cleanup: delete the snapshot from vendor cloud. Used after PR validation
# to avoid leaving orphaned images. Reads snapshot ID from manifest.
cleanup-snapshot:
	@command -v vultr-cli >/dev/null 2>&1 || { echo "Error: vultr-cli is required for cleanup"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "Error: jq is required for cleanup"; exit 1; }
	@if [ ! -f $(MANIFEST) ]; then echo "No manifest found, nothing to clean up"; exit 0; fi
	SNAPSHOT_ID=$$(jq -r '.builds[-1].artifact_id' $(MANIFEST)) && \
	echo "==> Deleting snapshot $$SNAPSHOT_ID..." && \
	vultr-cli snapshot delete "$$SNAPSHOT_ID" && \
	echo "==> Snapshot deleted" || echo "Warning: failed to delete snapshot $$SNAPSHOT_ID"

clean:
	rm -f $(MANIFEST)

# Prune: delete old snapshots and instances older than MAX_AGE hours (default 24).
# Use DRY_RUN=true to preview without deleting.
prune: prune-snapshots prune-instances

prune-snapshots:
	MAX_AGE=$${MAX_AGE_HOURS:-24}; \
	ARGS="--max-age-hours $$MAX_AGE --prefix pinner-s3-vultr-"; \
	if [ "$${DRY_RUN:-true}" = "true" ]; then ARGS="$$ARGS --dry-run"; fi; \
	python3 scripts/prune-snapshots.py $$ARGS

prune-instances:
	MAX_AGE=$${MAX_AGE_HOURS:-24}; \
	ARGS="--max-age-hours $$MAX_AGE --prefix pinner-s3-vultr-"; \
	if [ "$${DRY_RUN:-true}" = "true" ]; then ARGS="$$ARGS --dry-run"; fi; \
	python3 scripts/prune-instances.py $$ARGS
