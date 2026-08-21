"""The Fly card — machines, guests and volumes, and no money anywhere.

Fly exposes no spend over any public API, so the tests here are mostly about the two cost
drivers the machine list alone cannot see and the three failure codes that used to be one.
"""

from __future__ import annotations

import httpx

from rascal.config import get_settings
from rascal.services.billing.fly import fly_report


def _settings(**overrides: object):
    return get_settings().model_copy(
        update={"fly_api_token": "fo1_fake", "fly_app_name": "rascal-api", **overrides}
    )


def _client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


def _machine(mid: str, memory: int = 512, image: str = "reg/app:v1", **extra) -> dict:
    return {
        "id": mid,
        "state": "started",
        "region": "ord",
        "config": {
            "image": image,
            "guest": {"cpu_kind": "shared", "cpus": 1, "memory_mb": memory},
            **extra,
        },
    }


def _routed(machines: list | int, volumes: list | int = ()):
    def handler(request: httpx.Request) -> httpx.Response:
        body = volumes if str(request.url).endswith("/volumes") else machines
        if isinstance(body, int):
            return httpx.Response(body, json={"error": "no"})
        return httpx.Response(200, json=list(body))

    return handler


def _labels(report) -> str:
    return " ".join(f"{m.label} {m.value} {m.detail or ''}" for m in report.metrics)


async def test_unset_names_the_token_command() -> None:
    report = await fly_report(_client(_routed(500)), _settings(fly_api_token=None))
    assert report.status == "unconfigured"
    assert "fly tokens create readonly" in report.setup


async def test_401_403_and_404_say_three_different_things() -> None:
    """Regenerating a token when the app name is misspelled is a wasted afternoon."""
    details = {}
    for code in (401, 403, 404):
        async with _client(_routed(code)) as client:
            details[code] = (await fly_report(client, _settings())).detail
    assert len(set(details.values())) == 3
    assert "FLY_APP_NAME" in details[404]
    assert "organisation" in details[403]


async def test_an_empty_volume_list_is_a_fact_not_an_error() -> None:
    """Fly answers 200 `[]` rather than 404 when nothing is provisioned."""
    async with _client(_routed([_machine("a")], [])) as client:
        report = await fly_report(client, _settings())
    assert report.status == "ok"
    volumes = next(m for m in report.metrics if m.label == "Volumes")
    assert volumes.value == "none"


async def test_an_unattached_volume_is_flagged() -> None:
    """A volume bills on its provisioned size whether or not anything is attached to it."""
    volumes = [
        {"id": "v1", "name": "data", "size_gb": 3, "region": "ord", "attached_machine_id": None}
    ]
    async with _client(_routed([_machine("a")], volumes)) as client:
        report = await fly_report(client, _settings())
    row = next(m for m in report.metrics if m.label.startswith("volume ·"))
    assert row.tone == "warn"
    assert "still billed" in row.detail


async def test_a_machine_with_a_different_guest_is_flagged() -> None:
    """A size change is a line-item change and shows up on no other screen."""
    machines = [_machine(f"m{i}") for i in range(4)] + [_machine("odd", memory=2048)]
    async with _client(_routed(machines)) as client:
        report = await fly_report(client, _settings())
    drift = next(m for m in report.metrics if m.label == "Guest drift")
    assert drift.tone == "bad"
    assert "odd" in drift.detail
    assert "2,048 MB" in drift.value


async def test_a_missing_guest_block_does_not_raise() -> None:
    """`guest` is omitted from live responses in some states, and that is not a failure."""
    async with _client(_routed([{"id": "a", "state": "stopped", "config": {"image": "x:1"}}])) as c:
        report = await fly_report(c, _settings())
    assert report.status == "ok"


async def test_a_stale_image_on_a_scheduled_machine_is_still_flagged() -> None:
    """The original point of this card: a green deploy that never reached the cron machine."""
    machines = [
        _machine("a"),
        _machine("b"),
        _machine("cron", image="reg/app:old", schedule="hourly"),
    ]
    async with _client(_routed(machines)) as client:
        report = await fly_report(client, _settings())
    assert "STALE" in _labels(report)
    assert any(m.label == "Image drift" and m.tone == "bad" for m in report.metrics)


async def test_summary_is_never_requested() -> None:
    """`summary=true` returns `config: null`, blanking every field this card reads."""
    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(str(request.url))
        return httpx.Response(200, json=[])

    async with _client(handler) as client:
        await fly_report(client, _settings())
    assert seen and not any("summary" in url for url in seen)


async def test_a_volumes_outage_does_not_take_down_the_card() -> None:
    async with _client(_routed([_machine("a")], 503)) as client:
        report = await fly_report(client, _settings())
    assert report.status == "ok"
    assert next(m for m in report.metrics if m.label == "Volumes").value == "unreadable"


async def test_the_card_never_claims_a_stopped_machine_is_free() -> None:
    """ "5 machines, all stopped" reads as $0 and is wrong — the root filesystem still bills."""
    async with _client(_routed([_machine("a")])) as client:
        report = await fly_report(client, _settings())
    assert report.amount_cents is None
    assert "root filesystem" in report.detail
