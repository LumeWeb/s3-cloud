#!/usr/bin/env python3
"""Prune Vultr instances older than a threshold.

Deletes instances matching a label prefix that are older than the specified age.

Requires an explicit --prefix. There is no default prefix to prevent accidental
deletion of non-CI instances.

API docs:
    Instances: https://www.vultr.com/api/#tag/baremetal (also covers compute)

Usage:
    python3 prune-instances.py --prefix pinner-s3-vultr- --max-age-hours 24
    python3 prune-instances.py --prefix pinner-s3-vultr- --max-age-hours 24 --dry-run

Env:
    VULTR_API_KEY  Bearer token (read + delete scope)

Exit codes:
    0  success
    1  error (missing env, API failure, missing prefix)
"""

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.error

API_BASE = "https://api.vultr.com/v2"


def api_get(api_key: str, url: str) -> dict:
    """Make a GET request to the Vultr API v2."""
    headers = {"Authorization": f"Bearer {api_key}"}
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"API error {e.code}: {body}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Network error: {e}", file=sys.stderr)
        sys.exit(1)


def api_delete(api_key: str, url: str) -> bool:
    """Make a DELETE request to the Vultr API v2."""
    headers = {"Authorization": f"Bearer {api_key}"}
    req = urllib.request.Request(url, headers=headers, method="DELETE")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status == 204
    except urllib.error.HTTPError as e:
        print(f"  API error {e.code}: {e.read().decode()}", file=sys.stderr)
        return False
    except urllib.error.URLError:
        print("  Network error on delete", file=sys.stderr)
        return False


def parse_timestamp(ts_str: str) -> float:
    """Parse Vultr's ISO 8601 timestamp (e.g. '2026-07-16T12:34:56+00:00')."""
    try:
        return time.mktime(time.strptime(ts_str, "%Y-%m-%dT%H:%M:%S%z"))
    except (ValueError, TypeError):
        pass
    try:
        return time.mktime(time.strptime(ts_str, "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, TypeError):
        pass
    return 0.0


def main():
    parser = argparse.ArgumentParser(description="Prune old Vultr instances")
    parser.add_argument("--prefix", required=True, help="Instance label prefix to match (required)")
    parser.add_argument("--max-age-hours", type=int, default=24, help="Max age in hours before pruning (default: 24)")
    parser.add_argument("--dry-run", action="store_true", help="Print what would be deleted without deleting")
    parser.add_argument("--api-key", default=os.environ.get("VULTR_API_KEY", ""), help="Vultr API key (env: VULTR_API_KEY)")
    args = parser.parse_args()

    if not args.api_key:
        sys.exit("Error: --api-key or VULTR_API_KEY env required")

    now = time.time()
    cutoff = now - (args.max_age_hours * 3600)
    deleted = 0
    skipped = 0

    print(f"=== Instances (prefix: {args.prefix}, max age: {args.max_age_hours}h) ===")
    url = f"{API_BASE}/instances?per_page=100"
    while url:
        data = api_get(args.api_key, url)
        instances = data.get("instances", [])
        meta = data.get("meta", {})
        pagination = meta.get("pagination", {})
        next_page = pagination.get("links", {}).get("next")
        url = next_page if next_page else None

        for inst in instances:
            name = inst.get("label", inst.get("hostname", ""))
            if not name.startswith(args.prefix):
                continue

            inst_id = inst.get("id", "")
            created_str = inst.get("date_created", "")
            created_ts = parse_timestamp(created_str)

            if created_ts == 0:
                print(f"  SKIP {name} (id={inst_id}): could not parse date_created '{created_str}'")
                skipped += 1
                continue

            age_hours = (now - created_ts) / 3600

            if created_ts > cutoff:
                print(f"  KEEP {name} (id={inst_id}): {age_hours:.1f}h old")
                skipped += 1
                continue

            print(f"  DELETE {name} (id={inst_id}): {age_hours:.1f}h old")
            if args.dry_run:
                print(f"    [dry-run] would delete instance {inst_id}")
                deleted += 1
            else:
                if api_delete(args.api_key, f"{API_BASE}/instances/{inst_id}"):
                    print(f"    Deleted instance {inst_id}")
                    deleted += 1
                else:
                    skipped += 1

    print(f"\n=== Summary ===")
    print(f"Deleted: {deleted}")
    print(f"Skipped/Kept: {skipped}")
    if args.dry_run:
        print("(dry-run mode: nothing was actually deleted)")


if __name__ == "__main__":
    main()
