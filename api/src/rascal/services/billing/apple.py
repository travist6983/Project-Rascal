"""The membership fee, and an honest sentence about everything else.

**This module opens no socket and signs no token.** That is the finding, not a shortcut.

The App Store Connect API is free to call — there is no metered pricing anywhere in Apple's
documentation — and it publishes no billing endpoint at all. The only money Apple charges this
project is the flat Apple Developer Program membership, which is a published static price
retrievable from nowhere. So the card amortises the figure somebody typed in, names the setting
it came from exactly as the Tigris card does, and stops.

**Everything else App Store Connect could report does not exist yet.** Revenue, proceeds,
downloads, installs, impressions and conversion are all built from public App Store activity,
and an app that has never been released has none. `GET /v1/salesReports` needs at least one
unit sold and answers 404 on an empty period. App Analytics needs an Admin-role POST to create
a report request and then one to two days before the first report exists. There is no
same-day answer even after launch.

The things that *are* readable before launch — a build's processing state, TestFlight tester
counts, beta crash feedback — are release health rather than cost, and they belong on the Ops
panel in their own phase. `docs/blocked.md` records the credentials that would need.

So `status` is `"ok"` rather than `"unconfigured"`: nothing is missing here. The card renders
a sentence instead of a zero, because a zero on a costs page reads as a failed integration.
"""

from __future__ import annotations

from rascal.config import Settings
from rascal.services.billing.base import Metric, ProviderReport
from rascal.services.billing.format import APPLE_CONSOLE, LABELS


async def apple_report(settings: Settings) -> ProviderReport:
    """`async` with nothing to await, so the registry in `__init__.py` stays homogeneous.

    A sync signature would be more honest about what this does and would make this the one
    provider the fan-out has to special-case. One keyword is the cheaper of the two.
    """
    annual = settings.apple_membership_cents_per_year
    return ProviderReport(
        key="apple",
        label=LABELS["apple"],
        status="ok",
        amount_cents=annual // 12 if annual is not None else None,
        period_label="per month, amortised" if annual is not None else None,
        detail=(
            f"Estimated from APPLE_MEMBERSHIP_CENTS_PER_YEAR={annual}, divided by twelve. "
            "Apple publishes no billing API, and the App Store Connect API is free to call — "
            "the membership is the whole bill."
            if annual is not None
            else "Apple publishes no billing API. The Developer Program membership is a flat "
            "annual fee; set APPLE_MEMBERSHIP_CENTS_PER_YEAR to have it show here."
        ),
        metrics=(
            Metric(
                label="App Store",
                value="nothing until launch",
                detail="No revenue, downloads or analytics exist for an app that has never "
                "been released. This card will not render a zero that looks like a failure.",
            ),
        ),
        console_url=APPLE_CONSOLE,
    )


__all__ = ["apple_report"]
