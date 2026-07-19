#!/usr/bin/env python3
"""AWS Marketplace AMI submission helper.

Reads manifest.json (produced by Packer's manifest post-processor),
extracts the AMI ID, and provides instructions for submitting the AMI
to the AWS Marketplace Management Portal (AMMP).

AWS Marketplace does not expose a public API for product submission. The
actual submission is done manually through AMMP or via the Catalog API
after seller onboarding.

Usage:
    python3 submit.py --manifest manifest.json --version 1.0.0
    python3 submit.py --manifest manifest.json --dry-run=true
"""

import argparse
import json
import os
import subprocess
import sys


def get_ami_id(manifest_path: str) -> str:
    with open(manifest_path) as f:
        manifest = json.load(f)

    builds = manifest.get("builds", [])
    if not builds:
        sys.exit("Error: no builds in manifest")

    artifact_id = builds[-1].get("artifact_id", "")
    if not artifact_id:
        sys.exit("Error: empty artifact_id in manifest")

    # Packer AWS artifact_id includes region prefix like "us-east-1:ami-xxx"
    # Strip the region prefix for AWS CLI commands
    ami_id = artifact_id.split(":")[-1].strip()
    if not ami_id:
        sys.exit("Error: empty artifact_id in manifest")

    return ami_id


def main():
    parser = argparse.ArgumentParser(description="Submit AMI to AWS Marketplace")
    parser.add_argument("--manifest", default="manifest.json", help="Path to Packer manifest.json")
    parser.add_argument("--version", default="", help="App version string (e.g. 1.0.0)")
    parser.add_argument("--reason", default="Automated release", help="Reason for update")
    parser.add_argument("--dry-run", default="true", help="Print instructions without sharing (true/false)")
    args = parser.parse_args()

    dry_run = args.dry_run.lower() in ("true", "1", "yes")

    if not args.version:
        sys.exit("Error: --version required (e.g. 1.0.0)")

    ami_id = get_ami_id(args.manifest)
    print(f"AMI ID: {ami_id}")

    print("\n=== DRY RUN ===")
    print(f"AMI:     {ami_id}")
    print(f"Version: {args.version}")
    print(f"Reason:  {args.reason}")

    if not dry_run:
        # AWS Marketplace service account ID for AMI sharing
        mp_account = "679593333241"
        print(f"\nTo share this AMI with AWS Marketplace, run:")
        print(f"  aws ec2 modify-image-attribute \\")
        print(f"    --image-id {ami_id} \\")
        print(f"    --launch-permission \"Add=[{{UserId={mp_account}}}]\"")
        print(f"\nAfter sharing, submit the AMI via the AWS Marketplace Management Portal.")
    else:
        print("\nDry run: no API calls made.")
        print("Set --dry-run=false to print the sharing command.")


if __name__ == "__main__":
    main()
