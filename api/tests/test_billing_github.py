"""The GitHub Actions card.

The card exists because Actions billing has halted this repository twice (`docs/blocked.md`
§0, §0a), so the tests that matter most are the ones about what it refuses to claim.
"""

from __future__ import annotations

import httpx

from rascal.config import get_settings
from rascal.services.billing.github import github_report


def _settings(**overrides: object):
    base = {"github_billing_token": "ghp_fake", "github_account": "someone"}
    return get_settings().model_copy(update={**base, **overrides})


def _client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


def _usage(items: list[dict[str, object]]):
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"usageItems": items})

    return handler


def _status(code: int):
    return lambda request: httpx.Response(code, json={"message": "no"})


def _item(**overrides: object) -> dict[str, object]:
    return {
        "date": "2026-08-03",
        "product": "Actions",
        "sku": "Actions Linux",
        "quantity": 100,
        "unitType": "minutes",
        "netAmount": 0.80,
        **overrides,
    }


async def test_unset_github_names_the_permission_string() -> None:
    """ "Not connected" without naming the exact permission is a dead end."""
    report = await github_report(_client(_status(500)), _settings(github_billing_token=None))
    assert report.status == "unconfigured"
    assert "Plan" in report.setup
    assert "Read-only" in report.setup


async def test_dollars_are_not_treated_as_cents() -> None:
    """The inversion guard. GitHub sends dollars; Anthropic sends cents. $0.80 is 80 cents."""
    async with _client(_usage([_item(netAmount=0.80)])) as client:
        report = await github_report(client, _settings())
    assert report.amount_cents == 80


async def test_fractional_amounts_survive_summation() -> None:
    """Thirty rows of six-tenths of a cent are eighteen cents, not zero.

    Truncating each row — which is what `int()` on a `Decimal` does — is how a real month of
    Actions usage reports as free.
    """
    items = [_item(date=f"2026-08-{day:02d}", netAmount=0.006) for day in range(1, 31)]
    async with _client(_usage(items)) as client:
        report = await github_report(client, _settings())
    assert report.amount_cents == 18


async def test_another_product_is_not_actions_spend() -> None:
    """Copilot is billed in the same report and is not this card's subject."""
    items = [
        _item(netAmount=0.50, quantity=50),
        _item(product="Copilot", sku="Copilot", netAmount=10.00, quantity=1, unitType="users"),
    ]
    async with _client(_usage(items)) as client:
        report = await github_report(client, _settings())
    assert report.amount_cents == 50


async def test_actions_storage_is_spend_but_is_not_minutes() -> None:
    """Storage bills under the Actions product, so it belongs in the money and not the minutes.

    Adding GB-hours to minutes would produce a number with no unit at all, which is the reason
    the minutes figure filters on `unitType` while the total does not.
    """
    items = [
        _item(netAmount=0.50, quantity=50),
        _item(sku="Actions Storage", unitType="GB-hours", quantity=900, netAmount=0.30),
    ]
    async with _client(_usage(items)) as client:
        report = await github_report(client, _settings())
    minutes = next(m for m in report.metrics if m.label == "Actions minutes")
    assert minutes.value == "50 min"
    assert report.amount_cents == 80


async def test_sku_casing_does_not_change_the_total() -> None:
    """GitHub's own docs disagree on the SKU spelling, so the filter is on `product`."""
    items = [_item(sku="Actions Linux", netAmount=1.00), _item(sku="actions_linux", netAmount=1.00)]
    async with _client(_usage(items)) as client:
        report = await github_report(client, _settings())
    assert report.amount_cents == 200


async def test_the_card_never_claims_a_remaining_quota() -> None:
    """The API has no budget, quota or balance field, so the card must not imply one.

    A gauge reading "0 of 2,000 minutes" would have shown green through both prior halts.
    """
    async with _client(_usage([_item()])) as client:
        report = await github_report(client, _settings())
    rendered = " ".join(f"{m.label} {m.value} {m.detail or ''}" for m in report.metrics)
    assert "2,000" not in rendered and "2000" not in rendered
    budget = next(m for m in report.metrics if m.label == "Budget")
    assert budget.tone == "warn"
    assert "budget" in (budget.detail or "").lower()


async def test_a_daily_series_is_built_from_the_date_field() -> None:
    items = [
        _item(date="2026-08-03", netAmount=1.00),
        _item(date="2026-08-01", netAmount=2.00),
        _item(date="2026-08-02", netAmount=3.00),
    ]
    async with _client(_usage(items)) as client:
        report = await github_report(client, _settings())
    assert [p.day.day for p in report.series] == [1, 2, 3]
    assert [p.cents for p in report.series] == [200, 300, 100]
    assert report.series_unit == "cents"


async def test_a_404_is_a_missing_permission_not_a_missing_user() -> None:
    """GitHub answers a token without `Plan: read` with 404, which reads as a typo'd username."""
    async with _client(_status(404)) as client:
        report = await github_report(client, _settings())
    assert report.status == "error"
    assert "Plan" in report.detail
    assert "not the problem" in report.detail


async def test_401_403_and_404_say_three_different_things() -> None:
    details = {}
    for code in (401, 403, 404):
        async with _client(_status(code)) as client:
            details[code] = (await github_report(client, _settings())).detail
    assert len(set(details.values())) == 3
    assert "enhanced billing" in details[403]
