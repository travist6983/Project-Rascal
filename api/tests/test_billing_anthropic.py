"""The Anthropic card — the only one carrying a dollar total from a vendor that computes it.

Three of these guard arithmetic that was wrong before phase 100 and wrong in the flattering
direction: truncated fractional cents and an unpaginated read both make the bill look smaller.
"""

from __future__ import annotations

import httpx

from rascal.config import get_settings
from rascal.services.billing.anthropic import anthropic_report

COST = "cost_report"
USAGE = "usage_report/messages"


def _settings(**overrides: object):
    return get_settings().model_copy(update={"anthropic_admin_key": "sk-ant-admin-x", **overrides})


def _client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


def _bucket(day: str, rows: list[dict[str, object]]) -> dict[str, object]:
    return {"starting_at": f"{day}T00:00:00Z", "results": rows}


def _routed(cost: object, usage: object = None):
    """One handler, two endpoints. Either may be an int status or a JSON payload."""

    def handler(request: httpx.Request) -> httpx.Response:
        body = cost if COST in str(request.url) else usage
        if body is None:
            return httpx.Response(500, json={})
        if isinstance(body, int):
            return httpx.Response(body, json={"error": {"type": "authentication_error"}})
        return httpx.Response(200, json=body)

    return handler


async def test_unset_says_individual_accounts_cannot_have_an_admin_key() -> None:
    """The wall is not a setting, so the copy must not send somebody looking for one."""
    report = await anthropic_report(_client(_routed(401)), _settings(anthropic_admin_key=None))
    assert report.status == "unconfigured"
    assert "individual accounts" in report.setup


async def test_fractional_cents_are_not_truncated() -> None:
    """Thirty buckets of four-tenths of a cent are twelve cents, not zero.

    `int()` on a `Decimal` truncates. Doing that per bucket — which is what the code did before
    phase 100 — reported a real month of spend as free.
    """
    buckets = [
        _bucket(f"2026-08-{day:02d}", [{"amount": "0.4", "description": "claude"}])
        for day in range(1, 31)
    ]
    async with _client(_routed({"data": buckets, "has_more": False})) as client:
        report = await anthropic_report(client, _settings())
    assert report.amount_cents == 12


async def test_amount_is_read_as_cents_not_dollars() -> None:
    """`"123.45"` is $1.23. Reading it as dollars overstates the bill a hundredfold."""
    async with _client(_routed({"data": [_bucket("2026-08-01", [{"amount": "123.45"}])]})) as c:
        report = await anthropic_report(c, _settings())
    assert report.amount_cents == 123


async def test_pagination_is_followed() -> None:
    """An unpaginated read shows a partial month with no error — a total that is simply low."""
    pages = iter(
        [
            {
                "data": [_bucket("2026-08-01", [{"amount": "100"}])],
                "has_more": True,
                "next_page": "p2",
            },
            {"data": [_bucket("2026-08-02", [{"amount": "50"}])], "has_more": False},
        ]
    )

    def handler(request: httpx.Request) -> httpx.Response:
        if COST not in str(request.url):
            return httpx.Response(500, json={})
        return httpx.Response(200, json=next(pages))

    async with _client(handler) as client:
        report = await anthropic_report(client, _settings())
    assert report.amount_cents == 150
    assert len(report.series) == 2


async def test_has_more_without_a_cursor_terminates() -> None:
    """A vendor bug must not become an unbounded loop inside a request handler."""
    payload = {"data": [_bucket("2026-08-01", [{"amount": "10"}])], "has_more": True}
    async with _client(_routed(payload)) as client:
        report = await anthropic_report(client, _settings())
    assert report.status == "ok"


async def test_an_unrecognised_shape_is_an_error_not_a_zero() -> None:
    """A body with no `data` key is a shape change, not a month with no spending."""
    async with _client(_routed({"buckets": [], "object": "page"})) as client:
        report = await anthropic_report(client, _settings())
    assert report.status == "error"
    assert report.amount_cents is None


async def test_an_empty_data_list_is_a_real_quiet_month() -> None:
    async with _client(_routed({"data": [], "has_more": False})) as client:
        report = await anthropic_report(client, _settings())
    assert report.status == "ok"
    assert report.amount_cents == 0


async def test_401_and_403_both_name_the_admin_key() -> None:
    for code in (401, 403):
        async with _client(_routed(code)) as client:
            report = await anthropic_report(client, _settings())
        assert report.status == "error"
        assert "sk-ant-admin" in report.detail


async def test_the_usage_call_failing_leaves_the_dollar_figure_intact() -> None:
    """Tokens are decoration on this card. The money is its job."""
    cost = {"data": [_bucket("2026-08-01", [{"amount": "500"}])], "has_more": False}
    async with _client(_routed(cost, usage=None)) as client:
        report = await anthropic_report(client, _settings())
    assert report.status == "ok"
    assert report.amount_cents == 500
    assert not any(m.label == "Tokens in" for m in report.metrics)


async def test_a_usage_call_that_raises_still_leaves_the_dollar_figure_intact() -> None:
    """The harder half of the same promise, and the one a 500 does not exercise.

    `_fetch` turns an HTTP failure into a status code, but a read timeout raises. A bare
    `asyncio.gather` would propagate that and throw away a cost report that had already
    arrived — blanking the only vendor-computed dollar figure on the panel because its
    decorative sibling timed out.
    """
    cost = {"data": [_bucket("2026-08-01", [{"amount": "500"}])], "has_more": False}

    def handler(request: httpx.Request) -> httpx.Response:
        if COST in str(request.url):
            return httpx.Response(200, json=cost)
        raise httpx.ReadTimeout("usage report timed out", request=request)

    async with _client(handler) as client:
        report = await anthropic_report(client, _settings())
    assert report.status == "ok"
    assert report.amount_cents == 500
    assert not any(m.label == "Tokens in" for m in report.metrics)


async def test_a_cost_call_that_raises_is_not_swallowed() -> None:
    """The mirror of the above: the card's actual job failing must not render as success.

    `gather_reports` is the net that turns this into an `error` card, and it can only do that
    if the exception is re-raised rather than quietly becoming a report with no figure.
    """

    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("no route", request=request)

    async with _client(handler) as client:
        try:
            await anthropic_report(client, _settings())
        except httpx.ConnectError:
            return
    raise AssertionError("a failed cost report must propagate, not render as a card")


async def test_cache_creation_subkeys_are_read_by_their_documented_names() -> None:
    """`ephemeral_5m` is the name the shape suggests and it is not the name Anthropic uses."""
    cost = {"data": [_bucket("2026-08-01", [{"amount": "100"}])], "has_more": False}
    usage = {
        "data": [
            {
                "starting_at": "2026-08-01T00:00:00Z",
                "results": [
                    {
                        "uncached_input_tokens": 1_000_000,
                        "cache_read_input_tokens": 3_000_000,
                        "output_tokens": 500_000,
                        "cache_creation": {
                            "ephemeral_5m_input_tokens": 100_000,
                            "ephemeral_1h_input_tokens": 50_000,
                            "ephemeral_5m": 999_999_999,  # the wrong name, contributes nothing
                        },
                    }
                ],
            }
        ],
        "has_more": False,
    }
    async with _client(_routed(cost, usage)) as client:
        report = await anthropic_report(client, _settings())
    tokens_in = next(m for m in report.metrics if m.label == "Tokens in")
    assert tokens_in.value == "4.15M"  # 1M uncached + 3M read + 150K written
    assert next(m for m in report.metrics if m.label == "Cache hit rate").value == "72%"


async def test_the_card_names_the_priority_tier_exclusion() -> None:
    cost = {"data": [_bucket("2026-08-01", [{"amount": "100"}])], "has_more": False}
    async with _client(_routed(cost)) as client:
        report = await anthropic_report(client, _settings())
    assert "Priority Tier" in report.detail


async def test_no_console_url_is_the_pre_rename_host() -> None:
    """`console.anthropic.com` is the old host. A card that links there sends you nowhere."""
    report = await anthropic_report(_client(_routed(401)), _settings(anthropic_admin_key=None))
    assert "console.anthropic.com" not in f"{report.console_url} {report.setup} {report.detail}"
