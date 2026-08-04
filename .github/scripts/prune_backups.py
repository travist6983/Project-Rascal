"""Prune the backup prefix to 7 daily, 4 weekly, 12 monthly.

A grandfather-father-son retention, chosen because the failure modes it covers are
different: dailies catch "I broke it this morning", weeklies catch "I broke it and did not
notice for a fortnight", and monthlies catch "this row has been wrong since spring".

Every object is kept if *any* rule wants it. Deletes are logged individually, because a
retention job that quietly removed the wrong thing is the second-worst kind of backup bug.
"""

from __future__ import annotations

import os
import re
import sys
from collections import OrderedDict
from datetime import datetime

import boto3

BUCKET = os.environ.get("S3_BUCKET", "rascal-media-prod")
PREFIX = "backups/"
KEEP_DAILY = int(os.environ.get("KEEP_DAILY", "7"))
KEEP_WEEKLY = int(os.environ.get("KEEP_WEEKLY", "4"))
KEEP_MONTHLY = int(os.environ.get("KEEP_MONTHLY", "12"))

# backups/2026/08/rascal-20260804T081000Z.sql.gz
KEY_PATTERN = re.compile(r"rascal-(\d{8}T\d{6}Z)\.sql\.gz$")


def _taken_at(key: str) -> datetime | None:
    match = KEY_PATTERN.search(key)
    if match is None:
        return None
    return datetime.strptime(match.group(1), "%Y%m%dT%H%M%SZ")


def _newest_per_bucket(
    backups: list[tuple[str, datetime]], fmt: str, keep: int
) -> set[str]:
    """The newest key in each calendar bucket, for the most recent `keep` buckets."""
    by_bucket: OrderedDict[str, tuple[str, datetime]] = OrderedDict()
    for key, taken in sorted(backups, key=lambda item: item[1], reverse=True):
        label = taken.strftime(fmt)
        if label not in by_bucket:
            by_bucket[label] = (key, taken)
    return {key for key, _ in list(by_bucket.values())[:keep]}


def main() -> int:
    s3 = boto3.client("s3")

    backups: list[tuple[str, datetime]] = []
    unparseable: list[str] = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix=PREFIX):
        for obj in page.get("Contents", []):
            taken = _taken_at(obj["Key"])
            if taken is None:
                unparseable.append(obj["Key"])
            else:
                backups.append((obj["Key"], taken))

    if unparseable:
        # Never delete something we do not recognise. It is somebody's backup.
        print(f"leaving {len(unparseable)} unrecognised object(s) alone:")
        for key in unparseable[:10]:
            print(f"  ? {key}")

    if not backups:
        print("no backups found to prune")
        return 0

    keep = (
        _newest_per_bucket(backups, "%Y-%m-%d", KEEP_DAILY)
        | _newest_per_bucket(backups, "%G-W%V", KEEP_WEEKLY)  # ISO week
        | _newest_per_bucket(backups, "%Y-%m", KEEP_MONTHLY)
    )

    # Checked *before* deleting anything: cheap insurance against a bug in the selection
    # emptying the whole prefix.
    if not keep:
        print("::error::Retention selected nothing to keep. Refusing to delete anything.")
        return 1

    doomed = [(key, taken) for key, taken in backups if key not in keep]
    print(f"{len(backups)} backup(s): keeping {len(keep)}, deleting {len(doomed)}")

    for key, taken in sorted(doomed, key=lambda item: item[1]):
        print(f"  - {key}")
        s3.delete_object(Bucket=BUCKET, Key=key)
    return 0


if __name__ == "__main__":
    sys.exit(main())
