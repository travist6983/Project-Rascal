"""The S3 client's endpoint, which decides whether media goes to AWS or to Tigris.

RASCAL stores media on Tigris. It speaks S3, so boto3 works unchanged apart from being told
where to point — but nothing in the request shape reveals a misconfiguration. A client built
against the wrong endpoint presigns happily and hands the phone a URL for a bucket that does
not exist there, which fails at upload time looking like a credentials problem.

Nothing here talks to the network. Presigning is an offline signature computation.
"""

from __future__ import annotations

from collections.abc import Iterator
from urllib.parse import parse_qs, urlparse

import pytest

from rascal.config import get_settings
from rascal.services import s3

TIGRIS = "https://t3.storage.dev"


@pytest.fixture(autouse=True)
def _clear_client_cache() -> Iterator[None]:
    """`get_s3_client` is lru_cached, so a settings change is invisible without this."""
    s3.get_s3_client.cache_clear()
    yield
    s3.get_s3_client.cache_clear()


def _settings(**overrides: object):
    return get_settings().model_copy(update=overrides)


def test_no_endpoint_configured_targets_aws(monkeypatch: pytest.MonkeyPatch) -> None:
    """The default has to stay AWS, or setting this would break an existing deployment."""
    settings = _settings(s3_endpoint_url=None, s3_bucket="rascal-media", s3_region="us-east-2")
    monkeypatch.setattr(s3, "get_settings", lambda: settings)

    host = urlparse(s3.presign_put("k.jpg", "image/jpeg", settings)).netloc
    assert "amazonaws.com" in host


def test_endpoint_reaches_the_presigned_url(monkeypatch: pytest.MonkeyPatch) -> None:
    """The whole point: the URL handed to a phone must name the store we actually use."""
    settings = _settings(s3_endpoint_url=TIGRIS, s3_bucket="rascal-media-dev", s3_region="auto")
    monkeypatch.setattr(s3, "get_settings", lambda: settings)

    host = urlparse(s3.presign_put("k.jpg", "image/jpeg", settings)).netloc
    assert host.endswith("t3.storage.dev")
    assert "amazonaws.com" not in host


def test_virtual_addressing_puts_the_bucket_in_the_host(monkeypatch: pytest.MonkeyPatch) -> None:
    """boto3 flips to path-style for a custom endpoint unless told otherwise.

    The two styles sign differently, and the mismatch surfaces as a 404 against a bucket that
    demonstrably exists — an expensive afternoon. Pinning it here means a future edit to the
    botocore Config cannot quietly reintroduce that.
    """
    settings = _settings(s3_endpoint_url=TIGRIS, s3_bucket="rascal-media-dev", s3_region="auto")
    monkeypatch.setattr(s3, "get_settings", lambda: settings)

    url = urlparse(s3.presign_put("k.jpg", "image/jpeg", settings))
    assert url.netloc.startswith("rascal-media-dev.")
    assert not url.path.startswith("/rascal-media-dev/")


def test_the_signature_covers_the_configured_region(monkeypatch: pytest.MonkeyPatch) -> None:
    """Tigris wants `auto`. A real region here fails as a signature error, not a config one."""
    settings = _settings(s3_endpoint_url=TIGRIS, s3_bucket="rascal-media-dev", s3_region="auto")
    monkeypatch.setattr(s3, "get_settings", lambda: settings)

    # Parsed rather than substring-matched: the credential's slashes are percent-encoded in
    # the raw query string, so a naive `in` check looks for something that is never there.
    query = parse_qs(urlparse(s3.presign_put("k.jpg", "image/jpeg", settings)).query)
    assert query["X-Amz-Credential"][0].endswith("/auto/s3/aws4_request")


def test_presigned_url_carries_the_key_and_content_type(monkeypatch: pytest.MonkeyPatch) -> None:
    settings = _settings(s3_endpoint_url=TIGRIS, s3_bucket="rascal-media-dev", s3_region="auto")
    monkeypatch.setattr(s3, "get_settings", lambda: settings)

    url = s3.presign_put("children/c/entries/e/m.jpg", "image/jpeg", settings)
    assert "/children/c/entries/e/m.jpg" in url
    assert "X-Amz-Signature=" in url
