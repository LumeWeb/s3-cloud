.PHONY: build validate submit cleanup-snapshot prune all clean

TEMPLATE := template.pkr.hcl
MANIFEST := manifest.json
# Set DRY_RUN=true to print the API call without sending it
DRY_RUN  ?= true
# Version and reason passed from CI or manual invocation
VERSION  ?=
REASON   ?= Automated release
# Snapshot prefix: defaults to pinner-s3-do- for releases.
# CI sets SNAPSHOT_PREFIX=pinner-s3-do-pr-<number>- for PR builds.
SNAPSHOT_PREFIX ?= pinner-s3-do-

# Build: create snapshot in vendor cloud. Does NOT submit to marketplace.
all: build validate submit

build:
	packer init .
	packer validate .
	packer build -force -var "snapshot_prefix=$(SNAPSHOT_PREFIX)" .

# Validate: create temp VM from snapshot, run vendor img-check, destroy temp VM.
validate:
	@command -v doctl >/dev/null 2>&1 || { echo "Error: doctl is required for validation"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "Error: jq is required for validation"; exit 1; }
	bash ./scripts/validate.sh $(MANIFEST)

# Submit: push snapshot to vendor marketplace API. Requires DO_VENDOR_APP_ID.
submit:
	python3 submit.py --manifest $(MANIFEST) --dry-run=$(DRY_RUN) --version="$(VERSION)" --reason="$(REASON)"

# Cleanup: delete the snapshot from vendor cloud. Used after PR validation
# to avoid leaving orphaned images. Reads snapshot ID from manifest.
cleanup-snapshot:
	@command -v doctl >/dev/null 2>&1 || { echo "Error: doctl is required for cleanup"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "Error: jq is required for cleanup"; exit 1; }
	@if [ ! -f $(MANIFEST) ]; then echo "No manifest found, nothing to clean up"; exit 0; fi
	SNAPSHOT_ID=$$(jq -r '.builds[-1].artifact_id | split(":")[1]' $(MANIFEST)) && \
	echo "==> Deleting snapshot $$SNAPSHOT_ID..." && \
	doctl compute snapshot delete -f "$$SNAPSHOT_ID" && \
	echo "==> Snapshot deleted" || echo "Warning: failed to delete snapshot $$SNAPSHOT_ID"

clean:
	rm -f $(MANIFEST)

# Prune: delete old snapshots and droplets older than MAX_AGE hours (default 24).
# Protects snapshots linked to the marketplace listing via Vendor Portal API.
# Use DRY_RUN=true to preview without deleting.
prune:
	MAX_AGE=$${MAX_AGE_HOURS:-24}; \
	ARGS="--max-age-hours $$MAX_AGE"; \
	if [ "$${DRY_RUN:-true}" = "true" ]; then ARGS="$$ARGS --dry-run"; fi; \
	python3 scripts/prune-resources.py $$ARGS
