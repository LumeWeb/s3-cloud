#!/usr/bin/env python3
"""Submit a Packer-built snapshot to the Vultr Marketplace.

Reads manifest.json (produced by Packer's manifest post-processor),
extracts the snapshot ID, and provides instructions for assigning the
snapshot to a Vultr Marketplace app.

Vultr does not currently expose a public API for assigning snapshots to
marketplace app builds. The assignment must be done manually in the
Vultr Console:
    Marketplace -> <app> -> Build App Image -> Select snapshot

This script verifies the snapshot exists via the Vultr API v2 and
prints the assignment instructions.

Usage:
    python3 submit.py --manifest manifest.json
    python3 submit.py --manifest manifest.json --dry-run=true
    python3 submit.py --manifest manifest.json --dry-run=false --reason "v1.2.3"

Env:
    VULTR_API_KEY  Bearer token (or --api-key)

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

API_BASE = "https://api.vultr.com/v2"
MAX_RETRIES = 3
RETRY_DELAY = 5  # seconds


def get_snapshot_id(manifest_path: str) -> str:
    """Extract snapshot ID from Packer manifest.json.

    Vultr artifact_id is the snapshot UUID (e.g. "abc12345-...").
    """
    with open(manifest_path) as f:
        manifest = json.load(f)

    builds = manifest.get("builds", [])
    if not builds:
        sys.exit("Error: no builds in manifest")

    artifact_id = builds[-1].get("artifact_id", "")
    if not artifact_id:
        sys.exit(f"Error: empty artifact_id in manifest")

    return artifact_id.strip()


def verify_snapshot(api_key: str, snapshot_id: str) -> dict:
    """Verify the snapshot exists via Vultr API v2."""
    url = f"{API_BASE}/snapshots/{snapshot_id}"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    for attempt in range(1, MAX_RETRIES + 1):
        req = urllib.request.Request(url, headers=headers, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            if e.code == 404:
                print(f"Error: snapshot {snapshot_id} not found in Vultr account", file=sys.stderr)
                sys.exit(2)
            if 500 <= e.code < 600 and attempt < MAX_RETRIES:
                print(f"  Server error {e.code}, retry {attempt}/{MAX_RETRIES} in {RETRY_DELAY}s...")
                time.sleep(RETRY_DELAY)
                continue
            print(f"API error {e.code}: {e.read().decode()}", file=sys.stderr)
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
    parser = argparse.ArgumentParser(description="Submit snapshot to Vultr Marketplace")
    parser.add_argument("--manifest", default="manifest.json", help="Path to Packer manifest.json")
    parser.add_argument("--api-key", default=os.environ.get("VULTR_API_KEY", ""),
                        help="Vultr API key (env: VULTR_API_KEY)")
    parser.add_argument("--reason", default="Automated release", help="Reason for update")
    parser.add_argument("--version", default="", help="App version string (e.g. 1.0.0)")
    parser.add_argument("--dry-run", default="true", help="Print instructions without verifying (true/false)")
    args = parser.parse_args()

    dry_run = args.dry_run.lower() in ("true", "1", "yes")

    if not args.version:
        sys.exit("Error: --version required (e.g. 1.0.0)")

    snapshot_id = get_snapshot_id(args.manifest)
    print(f"Snapshot ID: {snapshot_id}")

    if dry_run:
        print("\n=== DRY RUN ===")
        print(f"Snapshot: {snapshot_id}")
        print(f"Version:  {args.version}")
        print(f"Reason:   {args.reason}")
        print("\nTo assign this snapshot to your Vultr Marketplace app:")
        print("  1. Go to the Vultr Console -> Marketplace")
        print(f"  2. Select your app -> Build App Image")
        print(f"  3. Select snapshot: {snapshot_id}")
        print("  4. Click Build App Image")
        return

    if not args.api_key:
        sys.exit("Error: --api-key or VULTR_API_KEY env required")

    snapshot = verify_snapshot(args.api_key, snapshot_id)
    print(f"Snapshot verified: {snapshot.get('description', snapshot_id)}")
    print(f"Status: {snapshot.get('status', 'unknown')}")
    print(f"Size: {snapshot.get('size', 'unknown')} bytes")
    print("\nTo publish this snapshot to the Vultr Marketplace:")
    print("  1. Go to the Vultr Console -> Marketplace")
    print(f"  2. Select your app -> Build App Image")
    print(f"  3. Select snapshot: {snapshot_id}")
    print("  4. Click Build App Image")
    print("  5. After building, go to Settings -> Make Public to submit for review")


if __name__ == "__main__":
    main()
