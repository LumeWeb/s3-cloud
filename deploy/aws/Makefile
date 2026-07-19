.PHONY: build validate submit cleanup-snapshot prune prune-snapshots prune-instances all clean

TEMPLATE := template.pkr.hcl
MANIFEST := manifest.json
DRY_RUN  ?= true
VERSION  ?=
REASON   ?= Automated release
SNAPSHOT_PREFIX ?= pinner-s3-aws-

all: build validate submit

VPC_ID   ?=
SUBNET_ID ?=

build:
	packer init .
	packer validate .
	packer build -force \
		-var "snapshot_prefix=$(SNAPSHOT_PREFIX)" \
		$(if $(VPC_ID),-var "vpc_id=$(VPC_ID)",) \
		$(if $(SUBNET_ID),-var "subnet_id=$(SUBNET_ID)",) \
		.

validate:
	@command -v aws >/dev/null 2>&1 || { echo "Error: aws CLI is required for validation"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "Error: jq is required for validation"; exit 1; }
	bash ./scripts/validate.sh $(MANIFEST)

submit:
	python3 submit.py --manifest $(MANIFEST) --dry-run=$(DRY_RUN) --version="$(VERSION)" --reason="$(REASON)"

cleanup-snapshot:
	@command -v aws >/dev/null 2>&1 || { echo "Error: aws CLI is required for cleanup"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "Error: jq is required for cleanup"; exit 1; }
	@if [ ! -f $(MANIFEST) ]; then echo "No manifest found, nothing to clean up"; exit 0; fi
	@AMI_ID=$$(jq -r '.builds[-1].artifact_id' $(MANIFEST) | sed 's/^[^:]*://') && \
	if [ -z "$$AMI_ID" ] || [ "$$AMI_ID" = "null" ]; then echo "No AMI ID in manifest"; exit 0; fi && \
	echo "==> Deregistering AMI $$AMI_ID..." && \
	aws ec2 deregister-image --image-id "$$AMI_ID" && \
	for SNAP in $$(aws ec2 describe-images --image-ids "$$AMI_ID" --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' --output text); do \
	  if [ -n "$$SNAP" ] && [ "$$SNAP" != "None" ]; then \
	    echo "==> Deleting snapshot $$SNAP..."; \
	    aws ec2 delete-snapshot --snapshot-id "$$SNAP"; \
	  fi; \
	done && \
	echo "==> AMI and snapshots cleaned up" || { echo "Warning: failed to clean up AMI $$AMI_ID"; exit 1; }

clean:
	rm -f $(MANIFEST)

prune: prune-snapshots prune-instances

prune-snapshots:
	MAX_AGE=$${MAX_AGE_HOURS:-24}; \
	ARGS="--max-age-hours $$MAX_AGE --prefix pinner-s3-aws-"; \
	if [ "$${DRY_RUN:-true}" = "true" ]; then ARGS="$$ARGS --dry-run"; fi; \
	python3 scripts/prune-snapshots.py $$ARGS

prune-instances:
	MAX_AGE=$${MAX_AGE_HOURS:-24}; \
	ARGS="--max-age-hours $$MAX_AGE --prefix pinner-s3-aws-"; \
	if [ "$${DRY_RUN:-true}" = "true" ]; then ARGS="$$ARGS --dry-run"; fi; \
	python3 scripts/prune-instances.py $$ARGS
