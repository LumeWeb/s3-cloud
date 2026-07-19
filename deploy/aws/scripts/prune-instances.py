#!/usr/bin/env python3
"""Prune old AWS EC2 instances created by CI.

Instances must have a Name tag matching the prefix and be older than
--max-age-hours.

Usage:
    python3 prune-instances.py --prefix pinner-s3-aws- --max-age-hours 24
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

    instances = run_aws("describe-instances", "--filters", f"Name=tag:Name,Values={args.prefix}*")
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=args.max_age_hours)

    to_terminate = []
    for res in instances.get("Reservations", []):
        for inst in res.get("Instances", []):
            state = inst.get("State", {}).get("Name", "")
            if state in ("terminated", "shutting-down"):
                continue
            launch = inst.get("LaunchTime", "")
            try:
                launch_dt = datetime.datetime.fromisoformat(launch.replace("Z", "+00:00"))
            except ValueError:
                continue
            if launch_dt > cutoff:
                continue
            name = next((t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"), "")
            if not name.startswith(args.prefix):
                continue
            to_terminate.append(inst["InstanceId"])
            print(f"{'Would terminate' if args.dry_run else 'Terminating'} {inst['InstanceId']} ({name}) launched {launch}")

    if args.dry_run or not to_terminate:
        return

    subprocess.run(["aws", "ec2", "terminate-instances", "--instance-ids"] + to_terminate, check=True)


if __name__ == "__main__":
    main()
