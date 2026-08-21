"""The Apple card — a membership fee and an honest sentence about everything else.

Apple publishes no billing API, and every App Store metric worth having is built from public
App Store activity an unreleased app has none of. The card's whole job is saying that without
rendering a zero.
"""

from __future__ import annotations

import inspect

from rascal.config import get_settings
from rascal.services.billing.apple import apple_report


async def test_apple_shows_no_figure_when_the_price_is_unset() -> None:
    """Nothing is missing, so this is `ok` rather than `unconfigured`."""
    report = await apple_report(
        get_settings().model_copy(update={"apple_membership_cents_per_year": None})
    )
    assert report.status == "ok"
    assert report.amount_cents is None
    assert "no billing API" in report.detail


async def test_apple_amortises_the_annual_fee_and_names_the_setting() -> None:
    """An estimate is allowed only when it names the number it came from."""
    priced = get_settings().model_copy(update={"apple_membership_cents_per_year": 9900})
    report = await apple_report(priced)
    assert report.amount_cents == 825
    assert report.period_label == "per month, amortised"
    assert "APPLE_MEMBERSHIP_CENTS_PER_YEAR" in report.detail


async def test_the_card_does_not_render_a_zero_that_looks_like_a_failure() -> None:
    """Pre-launch there is no revenue, and "$0.00 downloads" reads as a broken integration."""
    report = await apple_report(get_settings())
    metric = next(m for m in report.metrics if m.label == "App Store")
    assert metric.value == "nothing until launch"
    assert "never been released" in metric.detail


def test_apple_opens_no_socket() -> None:
    """Structural: the provider takes no client, so it cannot make a request.

    App Store Connect is free to call and publishes no billing endpoint, so there is nothing
    for this card to fetch. A signature that cannot reach the network is the cheapest proof.
    """
    parameters = list(inspect.signature(apple_report).parameters)
    assert parameters == ["settings"]
