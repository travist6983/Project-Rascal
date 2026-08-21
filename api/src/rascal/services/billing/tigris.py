"""What the archive actually weighs, read from the bucket the phone uploads to.

No credential of its own: this is the same S3 client `services/s3.py` presigns with, so the
card works the moment media uploads do and breaks in the same way if they are broken — which
makes it a storage-health check as much as a cost one.

**Walking the bucket is the only way.** There is no usage or billing REST API available to an
ordinary Tigris account. The one Tigris publishes lives at `mgmt.storage.dev`, is HMAC-signed
with a Provider ID issued only to partner-program members, and is not reachable with the
bucket's S3 keys — its existence is merely proof that Tigris holds the number server-side and
does not hand it over. There is no `GetBucketMetrics`, no Inventory, no Analytics, no Storage
Lens, and no `X-Tigris-*` response header anywhere that carries a size or an object count.
`HeadBucket` does not answer this question.

The walk is cheap — about twenty `ListObjectsV2` calls, well inside the free Class A
allowance. Accuracy is the problem, not cost, so two more calls buy two things the walk
cannot see at all:

**Lifecycle rules**, because a transition rule means some of those bytes bill below the
standard rate and the estimate is a ceiling rather than a figure.

**Incomplete multipart uploads**, whose parts are billed and do not appear in an object
listing. This service uploads media, so that is a live risk rather than a hypothetical.

**boto3 is synchronous**, so all three calls run in one worker thread. Listing a bucket inline
on the event loop would stall every other request on the machine for as long as the walk takes.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field
from typing import Any

from anyio import to_thread
from botocore.exceptions import ClientError

from rascal.config import Settings
from rascal.services.billing.base import Metric, ProviderReport
from rascal.services.billing.format import LABELS, TIGRIS_CONSOLE, bytes_binary
from rascal.services.s3 import get_s3_client

#: Stop walking the bucket after this many objects. A `ListObjectsV2` paginator will happily
#: enumerate a million keys one 1000-key page at a time, and a costs panel is not worth an
#: eight-second stall. Past the cap the card says the figure is a floor rather than a total,
#: because a silently truncated number that reads as exact is the worse failure.
_MAX_OBJECTS = 20_000

#: Three documented ways this measurement is lower than the bill, said on every render.
#: Measured is not billed, and the gap only ever goes one direction.
_UNDERCOUNT = (
    "This is measured, not billed. Three things bill and are not in it: soft-deleted objects "
    "(charged at full rate, hidden from listings), incomplete multipart parts, and minimum "
    "retention on objects that no longer exist."
)


@dataclass(frozen=True)
class _BucketFacts:
    count: int = 0
    total_bytes: int = 0
    by_prefix: dict[str, int] = field(default_factory=dict)
    truncated: bool = False
    lifecycle_rules: tuple[str, ...] = ()
    lifecycle_readable: bool = True
    open_multipart: int = 0
    oldest_multipart: dt.datetime | None = None


def _walk_bucket(bucket: str) -> _BucketFacts:
    """Every read this card makes, in one worker thread. boto3 is sync."""
    client = get_s3_client()
    count = 0
    total = 0
    by_prefix: dict[str, int] = {}
    truncated = False

    for page in client.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        for obj in page.get("Contents", []):
            count += 1
            size = int(obj.get("Size", 0))
            total += size
            prefix = str(obj.get("Key", "")).split("/", 1)[0] or "(root)"
            by_prefix[prefix] = by_prefix.get(prefix, 0) + size
            if count >= _MAX_OBJECTS:
                truncated = True
                break
        if truncated:
            break

    rules, readable = _lifecycle(client, bucket)
    open_uploads, oldest = _multipart(client, bucket)
    return _BucketFacts(
        count=count,
        total_bytes=total,
        by_prefix=by_prefix,
        truncated=truncated,
        lifecycle_rules=rules,
        lifecycle_readable=readable,
        open_multipart=open_uploads,
        oldest_multipart=oldest,
    )


def _lifecycle(client: Any, bucket: str) -> tuple[tuple[str, ...], bool]:
    """A one-line summary per rule, or `readable=False`.

    A bucket with no rules answers `NoSuchLifecycleConfiguration`, which is an answer rather
    than a failure. `GetBucketVersioning` is deliberately never called from this module: Tigris
    marks it unsupported in its own compatibility matrix, whatever the pricing page implies.
    """
    try:
        response = client.get_bucket_lifecycle_configuration(Bucket=bucket)
    except ClientError as error:
        code = error.response.get("Error", {}).get("Code", "")
        status = error.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        if code in ("NoSuchLifecycleConfiguration", "404", "NoSuchLifecycleConfigurationError"):
            return (), True
        if status == 404:
            return (), True
        return (), False
    except Exception:
        return (), False

    summaries: list[str] = []
    for rule in response.get("Rules", []):
        if str(rule.get("Status", "")).lower() != "enabled":
            continue
        scope = (rule.get("Filter") or {}).get("Prefix") or rule.get("Prefix") or "everything"
        # Both spellings: S3 returns `Transitions` as a list, and a single `Transition`
        # object is the older shape that some clients still emit.
        transitions = rule.get("Transitions") or (
            [rule["Transition"]] if "Transition" in rule else []
        )
        for transition in transitions:
            days = transition.get("Days")
            when = f"at {days}d" if days is not None else "on a date"
            summaries.append(f"{scope} → {transition.get('StorageClass', '?')} {when}")
        expiration = rule.get("Expiration") or {}
        if expiration.get("Days") is not None:
            summaries.append(f"expire {scope} after {expiration['Days']}d")
    return tuple(summaries), True


def _multipart(client: Any, bucket: str) -> tuple[int, dt.datetime | None]:
    """Count of open uploads and when the oldest started.

    Sizes would need a `ListParts` per upload and are not worth the calls — a count and an age
    is the whole signal. What matters is that these bytes exist, are billed, and are invisible
    to the object listing above.
    """
    try:
        response = client.list_multipart_uploads(Bucket=bucket)
    except Exception:
        return 0, None
    uploads = response.get("Uploads", []) or []
    started = [u["Initiated"] for u in uploads if u.get("Initiated")]
    return len(uploads), min(started) if started else None


async def tigris_report(settings: Settings) -> ProviderReport:
    facts = await to_thread.run_sync(_walk_bucket, settings.s3_bucket)

    metrics = [
        Metric(label="Stored", value=bytes_binary(facts.total_bytes), tone="ok"),
        Metric(
            label="Objects",
            value=f"{facts.count:,}{'+' if facts.truncated else ''}",
            detail="stopped counting at the cap" if facts.truncated else None,
            tone="warn" if facts.truncated else "plain",
        ),
    ]
    for prefix, size in sorted(facts.by_prefix.items(), key=lambda item: item[1], reverse=True)[:3]:
        metrics.append(Metric(label=f"{prefix}/", value=bytes_binary(size)))

    metrics.append(_lifecycle_metric(facts))
    if facts.open_multipart:
        oldest = facts.oldest_multipart
        metrics.append(
            Metric(
                label="Incomplete uploads",
                value=f"{facts.open_multipart:,}",
                detail="billed, and invisible to the object listing above."
                + (f" Oldest started {oldest.strftime('%b %-d')}." if oldest else ""),
                tone="bad",
            )
        )
    # Static, permanent and true. Every other storage vendor charges for egress, and Tigris
    # not charging is otherwise invisible on a page about what things cost.
    metrics.append(
        Metric(
            label="Egress",
            value="$0.00",
            detail="Tigris does not charge for egress, in any tier or geography",
            tone="ok",
        )
    )

    amount_cents: int | None = None
    detail = f"Tigris publishes no billing API. {_UNDERCOUNT}"
    if settings.storage_price_cents_per_gb_month is not None:
        # Binary gigabytes: Tigris bills in 2³⁰, unlike Neon. See `format.bytes_decimal`.
        gigabytes = facts.total_bytes / (1024**3)
        amount_cents = round(gigabytes * settings.storage_price_cents_per_gb_month)
        detail = (
            f"Estimated from STORAGE_PRICE_CENTS_PER_GB_MONTH="
            f"{settings.storage_price_cents_per_gb_month}. Not a figure from Tigris. "
            f"{_UNDERCOUNT}"
        )
    if facts.truncated:
        detail = f"{detail} The stored figure is a floor, not a total."

    return ProviderReport(
        key="tigris",
        label=LABELS["tigris"],
        status="ok",
        detail=detail,
        amount_cents=amount_cents,
        period_label="per month, estimated" if amount_cents is not None else None,
        metrics=tuple(metrics),
        console_url=TIGRIS_CONSOLE,
    )


def _lifecycle_metric(facts: _BucketFacts) -> Metric:
    if not facts.lifecycle_readable:
        return Metric(
            label="Lifecycle",
            value="unreadable",
            detail="the rules could not be read, so the estimate's rate is unverified",
            tone="warn",
        )
    if not facts.lifecycle_rules:
        return Metric(
            label="Lifecycle",
            value="no rules",
            detail="every byte bills at the standard rate",
        )
    return Metric(
        label="Lifecycle",
        value=f"{len(facts.lifecycle_rules)} rule{'s' if len(facts.lifecycle_rules) != 1 else ''}",
        detail="; ".join(facts.lifecycle_rules)
        + " — some bytes bill below the standard rate, so any estimate above is a ceiling",
        tone="ok",
    )


__all__ = ["tigris_report"]
