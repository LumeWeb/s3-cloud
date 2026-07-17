#!/usr/bin/env python3
"""Prune DigitalOcean droplets older than a threshold.

Deletes droplets matching a name prefix that are older than the specified age.

Requires an explicit --prefix. There is no default prefix to prevent accidental
deletion of non-CI droplets.

API docs:
    Droplets: https://docs.digitalocean.com/reference/api/reference/droplets/

Usage:
    python3 prune-instances.py --prefix pinner-s3-do- --max-age-hours 24
    python3 prune-instances.py --prefix pinner-s3-do- --max-age-hours 24 --dry-run

Env:
    DIGITALOCEAN_API_TOKEN  Bearer token (read + delete scope)

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

API_V2 = "https://api.digitalocean.com/v2"


def api_get(token: str, url: str) -> dict:
    """Make a GET request to the DO API."""
    headers = {"Authorization": f"Bearer {token}"}
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


def api_delete(token: str, url: str) -> bool:
    """Make a DELETE request to the DO API."""
    headers = {"Authorization": f"Bearer {token}"}
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


def get_all_pages(token: str, base_url: str, key: str) -> list:
    """Paginate through all results using DO's links.pages.next."""
    results = []
    url = base_url
    while url:
        data = api_get(token, url)
        results.extend(data.get(key, []))
        pages = data.get("links", {}).get("pages", {})
        url = pages.get("next")
    return results


def parse_timestamp(ts_str: str) -> float:
    """Parse DO's ISO 8601 timestamp (e.g. '2026-07-16T12:34:56Z')."""
    try:
        return time.mktime(time.strptime(ts_str, "%Y-%m-%dT%H:%M:%SZ"))
    except (ValueError, TypeError):
        return 0.0


def main():
    parser = argparse.ArgumentParser(description="Prune old DigitalOcean droplets")
    parser.add_argument("--prefix", required=True, help="Droplet name prefix to match (required)")
    parser.add_argument("--max-age-hours", type=int, default=24, help="Max age in hours before pruning (default: 24)")
    parser.add_argument("--dry-run", action="store_true", help="Print what would be deleted without deleting")
    parser.add_argument("--token", default=os.environ.get("DIGITALOCEAN_API_TOKEN", ""), help="DO API token (env: DIGITALOCEAN_API_TOKEN)")
    args = parser.parse_args()

    if not args.token:
        sys.exit("Error: --token or DIGITALOCEAN_API_TOKEN env required")

    now = time.time()
    cutoff = now - (args.max_age_hours * 3600)
    deleted = 0
    skipped = 0

    print(f"=== Droplets (prefix: {args.prefix}, max age: {args.max_age_hours}h) ===")
    droplets = get_all_pages(
        args.token,
        f"{API_V2}/droplets?per_page=200",
        "droplets",
    )
    for d in droplets:
        name = d.get("name", "")
        if not name.startswith(args.prefix):
            continue

        droplet_id = int(d["id"])
        created_str = d.get("created_at", "")
        created_ts = parse_timestamp(created_str)

        if created_ts == 0:
            print(f"  SKIP {name} (id={droplet_id}): could not parse created_at '{created_str}'")
            skipped += 1
            continue

        age_hours = (now - created_ts) / 3600

        if created_ts > cutoff:
            print(f"  KEEP {name} (id={droplet_id}): {age_hours:.1f}h old")
            skipped += 1
            continue

        print(f"  DELETE {name} (id={droplet_id}): {age_hours:.1f}h old")
        if args.dry_run:
            print(f"    [dry-run] would delete droplet {droplet_id}")
            deleted += 1
        else:
            if api_delete(args.token, f"{API_V2}/droplets/{droplet_id}"):
                print(f"    Deleted droplet {droplet_id}")
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
