"""The Neon card — consumption, a CU-hour chart, and deliberately no dollars.

The most important assertion here is the one that says the series carries no money. Neon
exposes exactly one monetary field in its whole API and it is a cap the owner configured;
pricing CU-hours into cents to fit the old `SeriesPoint` shape would have been rule 2 broken
to satisfy a dataclass.
"""

from __future__ import annotations

import httpx

from rascal.config import get_settings
from rascal.services.billing.neon import neon_report

HISTORY = "consumption_history"


def _settings(**overrides: object):
    return get_settings().model_copy(
        update={
            "neon_api_key": "napi_fake",
            "neon_project_id": "proj-1",
            "neon_org_id": "org-1",
            **overrides,
        }
    )


def _client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


PROJECT = {
    "synthetic_storage_size": 33_000_000,
    "compute_time_seconds": 3600,
    "written_data_bytes": 1_000,
    "data_transfer_bytes": 2_000,
    "consumption_period_start": "2026-08-01T00:00:00Z",
}


def _day(day: str, seconds: float, name: str = "compute_unit_seconds") -> dict:
    return {
        "timeframe_start": f"{day}T00:00:00Z",
        "metrics": [{"metric_name": name, "value": seconds}],
    }


def _routed(project: dict | int | None = None, history: object = None):
    def handler(request: httpx.Request) -> httpx.Response:
        if HISTORY in str(request.url):
            if history is None:
                return httpx.Response(500, json={})
            if isinstance(history, int):
                return httpx.Response(history, json={})
            return httpx.Response(200, json={"projects": [{"periods": [{"consumption": history}]}]})
        if isinstance(project, int):
            return httpx.Response(project, json={})
        return httpx.Response(200, json={"project": project if project is not None else PROJECT})

    return handler


async def test_unset_names_both_required_variables() -> None:
    report = await neon_report(_client(_routed()), _settings(neon_api_key=None))
    assert report.status == "unconfigured"
    assert "NEON_API_KEY" in report.setup and "NEON_PROJECT_ID" in report.setup


async def test_a_missing_storage_size_says_so_rather_than_rendering_zero_bytes() -> None:
    """`synthetic_storage_size` is optional and absent from Neon's own example response.

    `or 0` rendered "0.0 B" for it, which is a lie shaped exactly like a measurement.
    """
    project = {k: v for k, v in PROJECT.items() if k != "synthetic_storage_size"}
    async with _client(_routed(project, [])) as client:
        report = await neon_report(client, _settings())
    storage = next(m for m in report.metrics if m.label == "Storage")
    assert storage.value == "not reported"
    assert storage.tone == "warn"
    assert not any(m.value == "0.0 B" for m in report.metrics)


async def test_storage_is_reported_in_decimal_gigabytes() -> None:
    """Neon bills a GB-month as 10⁹ bytes. Gibibytes would understate it by seven percent."""
    async with _client(_routed(PROJECT, [])) as client:
        report = await neon_report(client, _settings())
    assert next(m for m in report.metrics if m.label == "Storage").value == "33.0 MB"


async def test_the_series_carries_cu_hours_and_never_cents() -> None:
    history = [_day("2026-08-01", 3600), _day("2026-08-02", 7200)]
    async with _client(_routed(PROJECT, history)) as client:
        report = await neon_report(client, _settings())
    assert report.series_unit == "CU-hours"
    assert all(point.cents is None for point in report.series)
    assert [point.value for point in report.series] == [1.0, 2.0]
    assert report.amount_cents is None


async def test_metrics_are_found_by_name_in_the_array() -> None:
    """`metrics` is an array of `{metric_name, value}`, not a flat dictionary."""
    entry = {
        "timeframe_start": "2026-08-01T00:00:00Z",
        "metrics": [
            {"metric_name": "data_transfer_bytes", "value": 999},
            {"metric_name": "compute_unit_seconds", "value": 1800},
        ],
    }
    async with _client(_routed(PROJECT, [entry])) as client:
        report = await neon_report(client, _settings())
    assert [point.value for point in report.series] == [0.5]


async def test_a_403_on_history_leaves_the_snapshot_card_standing() -> None:
    """A chart is a nice-to-have; consumption is the card's actual job."""
    async with _client(_routed(PROJECT, 403)) as client:
        report = await neon_report(client, _settings())
    assert report.status == "ok"
    assert report.series == ()
    assert "plan" in report.detail


async def test_no_org_id_means_no_history_call_and_a_sentence_saying_why() -> None:
    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(str(request.url))
        return httpx.Response(200, json={"project": PROJECT})

    async with _client(handler) as client:
        report = await neon_report(client, _settings(neon_org_id=None))
    assert not any(HISTORY in url for url in seen)
    assert "NEON_ORG_ID" in report.detail
    assert report.status == "ok"


async def test_the_card_carries_no_dollar_figure() -> None:
    async with _client(_routed(PROJECT, [_day("2026-08-01", 3600)])) as client:
        report = await neon_report(client, _settings())
    assert report.amount_cents is None
    assert "rather than dollars" in report.detail


async def test_a_snapshot_failure_errors_the_whole_card() -> None:
    async with _client(_routed(404, [])) as client:
        report = await neon_report(client, _settings())
    assert report.status == "error"
    assert "NEON_PROJECT_ID" in report.detail
