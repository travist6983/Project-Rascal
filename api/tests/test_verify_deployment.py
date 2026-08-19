"""The deploy check's own constant has to agree with the server's real thresholds.

`scripts/verify_deployment.py` asks the deployed API for a multipart upload by requesting
`MULTIPART_BYTES`. That constant is hand-written, and the server decides the split from
`multipart_threshold_bytes` and `multipart_chunk_bytes`. Nothing keeps the three in step except a
test that compares them — the same argument `test_verify_schema.py` makes about its two hand-written
lists.

Without this, raising the threshold past 16MB would turn the multipart check into a check of the
single-PUT path. It would fail loudly rather than silently, because the check asserts the plan came
back multipart — but it would fail against a deployment, on demand, which is a much more expensive
place to learn it than here.
"""

from __future__ import annotations

import importlib.util
import math
import sys
from pathlib import Path

import pytest

from rascal.config import get_settings

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "verify_deployment.py"


@pytest.fixture(scope="module")
def script():
    """Load the script by path, not by import — it lives in `scripts/`, which is not a package.

    **Registered in `sys.modules` before `exec_module`, unlike the sibling `test_verify_schema.py`
    fixture, and it has to be:** this script defines `@dataclass`es, and `dataclasses` resolves
    `cls.__module__` through `sys.modules` while building each one. Without the registration the
    lookup returns `None` and the whole load fails with `'NoneType' object has no attribute
    '__dict__'`, which reads as a bug in the script rather than in the loader. `verify_schema.py`
    happens to define no dataclasses, which is the only reason its fixture gets away with it.
    """
    spec = importlib.util.spec_from_file_location("verify_deployment", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["verify_deployment"] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        del sys.modules["verify_deployment"]
        raise
    return module


def test_the_request_size_is_over_the_servers_threshold(script) -> None:
    settings = get_settings()
    assert settings.multipart_threshold_bytes < script.MULTIPART_BYTES, (
        f"{script.MULTIPART_BYTES} is not over the {settings.multipart_threshold_bytes} threshold, "
        "so the deploy check would exercise the single-PUT path instead of multipart"
    )


def test_the_request_size_yields_at_least_two_parts(script) -> None:
    """One part is a passthrough. Assembly is only exercised from two upwards, and assembly is the
    thing `CompleteMultipartUpload` gets wrong."""
    settings = get_settings()
    parts = math.ceil(script.MULTIPART_BYTES / settings.multipart_chunk_bytes)
    assert parts >= 2, f"{script.MULTIPART_BYTES} splits into {parts} part(s) at the chunk size"


def test_the_payload_covers_the_whole_object_exactly(script) -> None:
    settings = get_settings()
    chunk = settings.multipart_chunk_bytes
    total = script.MULTIPART_BYTES
    parts = math.ceil(total / chunk)

    payload = script.multipart_payload(chunk, total, parts)

    assert len(payload) == total, "a short payload would be reported as a store defect"


def test_each_part_carries_a_distinct_byte(script) -> None:
    """This is what makes an out-of-order reassembly detectable. With one repeated byte the object
    would be the right length and the right content however the parts were arranged."""
    payload = script.multipart_payload(chunk := 8, total := 24, parts := 3)

    slices = [payload[i * chunk : (i + 1) * chunk] for i in range(parts)]
    assert [set(s) for s in slices] == [{1}, {2}, {3}]
    assert len(payload) == total


def test_a_ragged_last_part_is_not_padded(script) -> None:
    """The last part is whatever is left. Padding it would make the completed object larger than the
    file, which the store would accept and the length assertion would then blame on the store."""
    payload = script.multipart_payload(8, 20, 3)
    assert len(payload) == 20
    assert set(payload[16:]) == {3}
