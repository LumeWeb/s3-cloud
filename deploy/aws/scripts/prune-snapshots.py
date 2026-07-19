#!/usr/bin/env python3
"""Prune old AWS AMIs created by CI.

AMIs must match the given --prefix and be older than --max-age-hours.
Release AMIs (bare prefix without -pr- or -ci-) are never deleted.

Usage:
    python3 prune-snapshots.py --prefix pinner-s3-aws-pr-123- --max-age-hours 24
"""

import argparse
import datetime
import json
import subprocess
import sys


def run_aws(*args):
    cmd = ["aws", "ec2"] + list(args) + ["--output", "json"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"aws cli error: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout or "{}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--max-age-hours", type=int, default=24)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    # Only delete CI/prefixed AMIs, never release AMIs
    if "-pr-" not in args.prefix and "-ci-" not in args.prefix:
        print(f"Refusing to prune non-CI prefix: {args.prefix}")
        sys.exit(1)

    images = run_aws("describe-images", "--owners", "self")
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=args.max_age_hours)

    for img in images.get("Images", []):
        name = img.get("Name", "")
        if not name.startswith(args.prefix):
            continue
        created = img.get("CreationDate", "")
        try:
            created_dt = datetime.datetime.fromisoformat(created.replace("Z", "+00:00"))
        except ValueError:
            continue
        if created_dt > cutoff:
            continue

        print(f"{'Would delete' if args.dry_run else 'Deleting'} AMI {img['ImageId']} ({name}) created {created}")
        if args.dry_run:
            continue

        # Deregister AMI
        run_aws("deregister-image", "--image-id", img["ImageId"])
        # Delete associated snapshots
        for bdm in img.get("BlockDeviceMappings", []):
            ebs = bdm.get("Ebs", {})
            snap_id = ebs.get("SnapshotId")
            if snap_id:
                run_aws("delete-snapshot", "--snapshot-id", snap_id)


if __name__ == "__main__":
    main()
