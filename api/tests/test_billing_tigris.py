"""The Tigris card — a bucket walk, and the two things a bucket walk cannot see.

Incomplete multipart parts and lifecycle rules both change what the archive costs and neither
appears in an object listing. The rest of these are about the card refusing to overstate its
own accuracy.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from moto import mock_aws

from rascal.config import get_settings
from rascal.services import s3
from rascal.services.billing import tigris as tigris_module
from rascal.services.billing.tigris import tigris_report


@pytest.fixture
def bucket() -> Iterator[str]:
    settings = get_settings()
    s3.get_s3_client.cache_clear()
    with mock_aws():
        s3.get_s3_client().create_bucket(
            Bucket=settings.s3_bucket,
            CreateBucketConfiguration={"LocationConstraint": settings.s3_region},
        )
        yield settings.s3_bucket
    s3.get_s3_client.cache_clear()


def _metric(report, label: str):
    return next(m for m in report.metrics if m.label == label)


async def test_a_bucket_with_no_lifecycle_rules_says_so(bucket: str) -> None:
    """No rules is an answer, not a failure — S3 signals it with an error code."""
    report = await tigris_report(get_settings())
    assert report.status == "ok"
    lifecycle = _metric(report, "Lifecycle")
    assert lifecycle.value == "no rules"
    assert "standard rate" in lifecycle.detail


async def test_a_lifecycle_rule_is_summarised_and_caps_the_estimate(bucket: str) -> None:
    """A transition rule means some bytes bill below the standard rate, so a figure is a ceiling."""
    s3.get_s3_client().put_bucket_lifecycle_configuration(
        Bucket=bucket,
        LifecycleConfiguration={
            "Rules": [
                {
                    "ID": "cold",
                    "Status": "Enabled",
                    "Filter": {"Prefix": "children/"},
                    "Transitions": [{"Days": 30, "StorageClass": "GLACIER_IR"}],
                }
            ]
        },
    )
    report = await tigris_report(get_settings())
    lifecycle = _metric(report, "Lifecycle")
    assert lifecycle.value == "1 rule"
    assert "GLACIER_IR" in lifecycle.detail
    assert "ceiling" in lifecycle.detail


async def test_an_incomplete_multipart_upload_is_flagged(bucket: str) -> None:
    """Abandoned parts are billed and never appear in an object listing."""
    s3.get_s3_client().create_multipart_upload(Bucket=bucket, Key="children/big.mov")
    report = await tigris_report(get_settings())
    incomplete = _metric(report, "Incomplete uploads")
    assert incomplete.value == "1"
    assert incomplete.tone == "bad"
    assert "invisible to the object listing" in incomplete.detail


async def test_a_clean_bucket_carries_no_incomplete_upload_row(bucket: str) -> None:
    report = await tigris_report(get_settings())
    assert not any(m.label == "Incomplete uploads" for m in report.metrics)


async def test_truncation_says_the_number_is_a_floor(bucket: str, monkeypatch) -> None:
    """A silently truncated total that reads as exact is the worse failure."""
    monkeypatch.setattr(tigris_module, "_MAX_OBJECTS", 3)
    for i in range(5):
        s3.get_s3_client().put_object(Bucket=bucket, Key=f"children/{i}.jpg", Body=b"x" * 10)
    report = await tigris_report(get_settings())
    assert _metric(report, "Objects").value == "3+"
    assert "floor, not a total" in report.detail


async def test_the_card_names_what_it_cannot_measure(bucket: str) -> None:
    """Measured is not billed, and the gap only ever runs one way."""
    report = await tigris_report(get_settings())
    assert "soft-deleted" in report.detail
    assert "multipart" in report.detail


async def test_egress_is_reported_as_free(bucket: str) -> None:
    """Every other storage vendor charges for it; Tigris not charging is otherwise invisible."""
    egress = _metric(await tigris_report(get_settings()), "Egress")
    assert egress.value == "$0.00"
    assert egress.tone == "ok"


async def test_stored_bytes_use_binary_gigabytes(bucket: str) -> None:
    """Tigris bills 2³⁰ per GB. Neon bills 10⁹. The two divisors must not converge."""
    s3.get_s3_client().put_object(Bucket=bucket, Key="children/a.jpg", Body=b"x" * 1024)
    report = await tigris_report(get_settings())
    assert _metric(report, "Stored").value == "1.0 KB"


async def test_a_configured_price_produces_a_labelled_estimate(bucket: str) -> None:
    s3.get_s3_client().put_object(Bucket=bucket, Key="children/a.jpg", Body=b"x" * 1024)
    priced = get_settings().model_copy(update={"storage_price_cents_per_gb_month": 2000})
    report = await tigris_report(priced)
    assert report.amount_cents is not None
    assert "STORAGE_PRICE_CENTS_PER_GB_MONTH" in report.detail
    assert "Not a figure from Tigris" in report.detail
