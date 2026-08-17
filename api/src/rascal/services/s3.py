"""The S3 client and the presigning it does. The server never proxies bytes.

Presigning is an offline signature computation, so it runs inline. The two calls that do
touch the network — initiating and completing a multipart upload — run in a thread so they
never block the event loop.
"""

from __future__ import annotations

import asyncio
from functools import lru_cache
from typing import Any

import boto3
from botocore.config import Config

from rascal.config import Settings, get_settings


@lru_cache(maxsize=1)
def get_s3_client() -> Any:
    settings = get_settings()
    return boto3.client(
        "s3",
        region_name=settings.s3_region,
        aws_access_key_id=settings.aws_access_key_id,
        aws_secret_access_key=settings.aws_secret_access_key,
        # None targets real AWS. Set it to reach any S3-compatible store — Tigris in this
        # deployment. Presigning signs against whatever endpoint the client was built with,
        # so the URLs handed to a phone point at the same place these calls do.
        endpoint_url=settings.s3_endpoint_url,
        # SigV4 so presigned URLs work in every region, including the ones that refuse SigV2.
        # Virtual addressing is stated rather than left to boto3's default, which flips to
        # path-style for a custom endpoint — the two produce different signatures, and the
        # mismatch surfaces as a 404 on a bucket that demonstrably exists.
        config=Config(
            signature_version="s3v4",
            s3={"addressing_style": "virtual"},
            retries={"max_attempts": 3},
        ),
    )


def presign_put(key: str, content_type: str, settings: Settings) -> str:
    return get_s3_client().generate_presigned_url(
        "put_object",
        Params={"Bucket": settings.s3_bucket, "Key": key, "ContentType": content_type},
        ExpiresIn=settings.presign_ttl_seconds,
    )


def presign_get(key: str, settings: Settings) -> str:
    """A short-lived URL a client can read the bytes from directly.

    The counterpart to `presign_put`, and the reason the archive is viewable at all: the
    bucket is private, so without this the objects are write-only — the bytes survive but
    nothing can render them.

    Deliberately short-lived and minted on demand rather than stored. A URL in the database
    would outlive its signature and start failing in a way that looks like data loss.
    """
    return get_s3_client().generate_presigned_url(
        "get_object",
        Params={"Bucket": settings.s3_bucket, "Key": key},
        ExpiresIn=settings.presign_ttl_seconds,
    )


def presign_part(key: str, upload_id: str, part_number: int, settings: Settings) -> str:
    return get_s3_client().generate_presigned_url(
        "upload_part",
        Params={
            "Bucket": settings.s3_bucket,
            "Key": key,
            "UploadId": upload_id,
            "PartNumber": part_number,
        },
        ExpiresIn=settings.presign_ttl_seconds,
    )


async def create_multipart_upload(key: str, content_type: str, settings: Settings) -> str:
    response = await asyncio.to_thread(
        get_s3_client().create_multipart_upload,
        Bucket=settings.s3_bucket,
        Key=key,
        ContentType=content_type,
    )
    return response["UploadId"]


async def complete_multipart_upload(
    key: str, upload_id: str, parts: list[dict[str, Any]], settings: Settings
) -> None:
    await asyncio.to_thread(
        get_s3_client().complete_multipart_upload,
        Bucket=settings.s3_bucket,
        Key=key,
        UploadId=upload_id,
        MultipartUpload={"Parts": parts},
    )


async def delete_objects(keys: list[str], settings: Settings) -> int:
    """Remove objects from the bucket. Returns how many were requested.

    **The first code in this service that deletes a byte from storage**, and it arrives with
    phase 66 because an erasure request cannot be honoured by forgetting the row and keeping
    the photograph. `docs/investigations/account-deletion.md` found the absence; **phase 38
    needs this too**, because D3 promises lapsed media is deleted and nothing could carry that
    out either.

    **`delete_objects` in batches of 1000, not `delete_object` in a loop.** A child's archive is
    thousands of files, and one request per object is thousands of round trips inside a job
    somebody is waiting on. 1000 is the API's own limit.

    **Runs in a thread**, like the two multipart calls above, because it touches the network and
    the event loop must not stop for it.

    **A missing key is not an error.** S3 answers success for a delete of something that is not
    there, and that is the behaviour this wants: a retried deletion, or a row whose upload never
    completed, must not strand the whole request. The bucket's 30-day soft delete is a net under
    all of this — **not** a licence to treat the call as reversible.
    """
    if not keys:
        return 0

    client = get_s3_client()
    bucket = settings.s3_bucket

    def _delete(batch: list[str]) -> None:
        client.delete_objects(
            Bucket=bucket,
            Delete={"Objects": [{"Key": key} for key in batch], "Quiet": True},
        )

    for start in range(0, len(keys), 1000):
        await asyncio.to_thread(_delete, keys[start : start + 1000])
    return len(keys)
