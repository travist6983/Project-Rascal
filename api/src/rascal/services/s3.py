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
