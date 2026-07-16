#!/usr/bin/env python3
"""Submit a Packer-built snapshot to the DigitalOcean Vendor Portal API.

Reads manifest.json (produced by Packer's manifest post-processor),
extracts the snapshot image ID, and PATCHes the Vendor Portal to update
the marketplace listing.

Usage:
    python3 submit.py --manifest manifest.json
    python3 submit.py --manifest manifest.json --dry-run=true
    python3 submit.py --manifest manifest.json --dry-run=false --reason "v1.2.3"

Env:
    DIGITALOCEAN_API_TOKEN  Bearer token (or --token)
    DO_VENDOR_APP_ID         Marketplace app ID from Vendor Portal URL (or --app-id)

Exit codes:
    0  success (or dry-run)
    1  validation error (missing args/env, bad manifest)
    2  API error (4xx/5xx after retries)
"""

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error

API_BASE = "https://api.digitalocean.com/api/v1/vendor-portal/apps"
MAX_RETRIES = 3
RETRY_DELAY = 5  # seconds


def get_image_id(manifest_path: str) -> int:
    """Extract snapshot ID from Packer manifest.json.

    artifact_id format: "region:snapshot_id" (e.g. "nyc3:123456789")
    """
    with open(manifest_path) as f:
        manifest = json.load(f)

    builds = manifest.get("builds", [])
    if not builds:
        sys.exit("Error: no builds in manifest")

    artifact_id = builds[-1].get("artifact_id", "")
    if ":" not in artifact_id:
        sys.exit(f"Error: unexpected artifact_id format: {artifact_id}")

    snapshot_id = artifact_id.split(":")[-1]
    try:
        return int(snapshot_id)
    except ValueError:
        sys.exit(f"Error: snapshot ID is not an integer: {snapshot_id}")


def submit(app_id: str, token: str, image_id: int, reason: str,
           version: str, dry_run: bool) -> dict:
    """PATCH the Vendor Portal API with the new image ID."""
    url = f"{API_BASE}/{app_id}"
    body = {
        "reasonForUpdate": reason,
        "imageId": image_id,
        "osVersion": "Ubuntu 22.04",
        "softwareIncluded": [
            {"name": "Pinner S3 Server", "version": version},
        ],
    }
    data = json.dumps(body).encode()
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
    }

    if dry_run:
        print("=== DRY RUN ===")
        print(f"PATCH {url}")
        print(f"Authorization: Bearer {'<redacted>' if token else '<missing>'}")
        print(f"Body: {json.dumps(body, indent=2)}")
        return {"dry_run": True, "url": url, "body": body}

    for attempt in range(1, MAX_RETRIES + 1):
        req = urllib.request.Request(url, data=data, headers=headers, method="PATCH")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                result = json.loads(resp.read().decode())
                print(f"Success: image {image_id} submitted to app {app_id}")
                print(f"Vendor Portal: https://cloud.digitalocean.com/vendorportal")
                return result
        except urllib.error.HTTPError as e:
            body_text = e.read().decode()
            if 500 <= e.code < 600 and attempt < MAX_RETRIES:
                print(f"  Server error {e.code}, retry {attempt}/{MAX_RETRIES} in {RETRY_DELAY}s...")
                time.sleep(RETRY_DELAY)
                continue
            print(f"API error {e.code}: {body_text}", file=sys.stderr)
            sys.exit(2)
        except urllib.error.URLError as e:
            if attempt < MAX_RETRIES:
                print(f"  Network error: {e}, retry {attempt}/{MAX_RETRIES} in {RETRY_DELAY}s...")
                time.sleep(RETRY_DELAY)
                continue
            print(f"Network error after {MAX_RETRIES} attempts: {e}", file=sys.stderr)
            sys.exit(2)

    print("Exhausted all retries", file=sys.stderr)
    sys.exit(2)


def main():
    parser = argparse.ArgumentParser(description="Submit snapshot to DO Vendor Portal API")
    parser.add_argument("--manifest", default="manifest.json", help="Path to Packer manifest.json")
    parser.add_argument("--app-id", default=os.environ.get("DO_VENDOR_APP_ID", ""),
                        help="Vendor Portal app ID (env: DO_VENDOR_APP_ID)")
    parser.add_argument("--token", default=os.environ.get("DIGITALOCEAN_API_TOKEN", ""),
                        help="DO API token (env: DIGITALOCEAN_API_TOKEN)")
    parser.add_argument("--reason", default="Automated release", help="Reason for update")
    parser.add_argument("--version", default="", help="App version string (e.g. 1.0.0)")
    parser.add_argument("--dry-run", default="true", help="Print request without sending (true/false)")
    args = parser.parse_args()

    dry_run = args.dry_run.lower() in ("true", "1", "yes")

    if not args.app_id:
        sys.exit("Error: --app-id or DO_VENDOR_APP_ID env required")
    if not dry_run and not args.token:
        sys.exit("Error: --token or DIGITALOCEAN_API_TOKEN env required")
    if not args.version:
        sys.exit("Error: --version required (e.g. 1.0.0)")

    image_id = get_image_id(args.manifest)
    print(f"Snapshot image ID: {image_id}")

    submit(args.app_id, args.token, image_id, args.reason, args.version, dry_run)


if __name__ == "__main__":
    main()
