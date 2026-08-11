"""A child's avatar: presigning it in, presigning it back out.

Deliberately not a `media` row. `media` belongs to an *entry*, and filing a picture of a
child in the archive as some entry's artifact would put a wrong row in a permanent record —
which is why the iOS client kept avatars on the device rather than reusing
`POST /media/upload-url`. An avatar is a property of the child, so it is keyed like one and
lives only in `children.avatar_key`.

The upload is a single PUT and never multipart: this is a ~512px square, and the multipart
machinery exists for video.
"""

from __future__ import annotations

import uuid

from rascal.config import Settings
from rascal.errors import not_found, validation_failed
from rascal.models import Child
from rascal.services import s3

# What the phone can actually produce, mapped to the suffix the key gets. An allow-list
# rather than a regex on `image/*`: the extension has to be derived from something, and a
# content type nothing can decode is better refused at the presign than discovered when the
# archive tries to render it years later.
AVATAR_CONTENT_TYPES: dict[str, str] = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/heic": ".heic",
}

# A 512px square JPEG is tens of kilobytes. This is not a guess at the right size, it is a
# ceiling that stops a full-resolution original being uploaded here by mistake.
MAX_AVATAR_BYTES = 5 * 1024 * 1024


def build_avatar_key(child_id: uuid.UUID, content_type: str) -> str:
    """`children/{id}/avatar/{uuid}{ext}` — same child-first prefix as media.

    A fresh UUID per upload rather than a stable `avatar.jpg`. Overwriting one key would make
    every cached copy and every presigned URL already in flight point at the new image, and a
    replaced avatar would be indistinguishable from a corrupted one.
    """
    return f"children/{child_id}/avatar/{uuid.uuid4()}{AVATAR_CONTENT_TYPES[content_type]}"


def plan_avatar_upload(
    child_id: uuid.UUID, *, content_type: str, size: int, settings: Settings
) -> tuple[str, str]:
    """Returns `(upload_url, avatar_key)`. Writes nothing.

    The caller `PATCH`es `avatar_key` onto the child once the PUT succeeds, so a presign that
    the phone abandons leaves an orphaned object rather than a child record pointing at bytes
    that never arrived. Of the two, only the second is visible to a parent.
    """
    if content_type not in AVATAR_CONTENT_TYPES:
        raise validation_failed(
            "An avatar must be a JPEG, PNG, or HEIC image.",
            field="content_type",
        )
    if size <= 0 or size > MAX_AVATAR_BYTES:
        raise validation_failed(
            f"An avatar must be between 1 byte and {MAX_AVATAR_BYTES} bytes.",
            field="bytes",
        )

    key = build_avatar_key(child_id, content_type)
    return s3.presign_put(key, content_type, settings), key


def presign_avatar_read(child: Child, settings: Settings) -> str:
    """A short-lived read URL for the stored avatar.

    404 rather than a null URL when there is no avatar: "this child has no avatar" and "here
    is a URL that will not resolve" are different answers, and only one of them lets a client
    fall back to initials without a round trip that fails.
    """
    if child.avatar_key is None:
        raise not_found("Avatar")
    return s3.presign_get(child.avatar_key, settings)
