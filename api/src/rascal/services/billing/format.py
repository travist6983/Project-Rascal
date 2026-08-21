"""Units, names and links — the things every vendor module needs and none of them owns.

Split out when `providers.py` became seven files, because the alternative was seven copies of
`_bytes` or one vendor importing another to borrow it. Nothing here knows about a vendor; it
knows about dollars, bytes, tokens and rounding.

**The two divisors in this file are deliberately not one divisor.** `bytes_binary` divides by
2³⁰ and `bytes_decimal` by 10⁹, because Tigris bills in binary gigabytes and Neon bills in
decimal ones. Unifying them would be a seven-percent error in whichever vendor lost, silently,
on the screen that exists to be trusted about exactly this.
"""

from __future__ import annotations

from decimal import ROUND_HALF_UP, Decimal

#: Every provider's display name, in one place because the fan-out in `__init__.py` needs them
#: to label a report whose builder raised before it could name itself.
LABELS = {
    "anthropic": "Anthropic",
    "github": "GitHub Actions",
    "fly": "Fly.io",
    "neon": "Neon",
    "tigris": "Tigris (storage)",
    "resend": "Resend",
    "apple": "Apple",
}

#: Where to go and look at the real invoice. Deliberately the billing page rather than the
#: dashboard root wherever the vendor has one — a card that says "no billing API" and then
#: links at a homepage has sent you nowhere.
ANTHROPIC_CONSOLE = "https://platform.claude.com/cost"
GITHUB_CONSOLE = "https://github.com/settings/billing/budgets"
RESEND_CONSOLE = "https://resend.com/audiences"
FLY_CONSOLE = "https://fly.io/dashboard"
NEON_CONSOLE = "https://console.neon.tech"
TIGRIS_CONSOLE = "https://console.tigris.dev"
APPLE_CONSOLE = "https://developer.apple.com/account/resources/"


def money(cents: int) -> str:
    return f"${cents / 100:,.2f}"


def bytes_binary(count: int) -> str:
    """Powers of 1024. What Tigris bills in, and what a filesystem means by "GB"."""
    size = float(count)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:,.1f} {unit}" if unit != "B" else f"{int(size):,} B"
        size /= 1024
    return f"{size:,.1f} TB"


def bytes_decimal(count: int) -> str:
    """Powers of 1000. What Neon bills in, and what a vendor's pricing page means by "GB".

    Seven percent apart from `bytes_binary` at the gigabyte and growing. Neon's own docs are
    explicit that a GB-month is 10⁹ bytes, so reporting its storage in gibibytes would
    understate the figure the invoice is computed from.
    """
    size = float(count)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1000 or unit == "TB":
            return f"{size:,.1f} {unit}" if unit != "B" else f"{int(size):,} B"
        size /= 1000
    return f"{size:,.1f} TB"


def tokens(count: int) -> str:
    """`12_400_000` → `"12.4M"`. Tokens are counted in millions and priced in millions."""
    if count < 1_000:
        return f"{count:,}"
    if count < 1_000_000:
        return f"{count / 1_000:,.1f}K"
    if count < 1_000_000_000:
        return f"{count / 1_000_000:,.2f}M"
    return f"{count / 1_000_000_000:,.2f}B"


def cents_from_decimal(total: Decimal) -> int:
    """Round a running `Decimal` of cents to an integer, once, half-up.

    **Rounded here and nowhere else.** Two vendors reach this function from opposite
    directions — Anthropic hands over a decimal string already denominated in cents, GitHub a
    JSON number of dollars multiplied by a hundred — and both have fractional-cent line items
    that only add up to money in aggregate. Truncating per row, which is what `int()` on a
    `Decimal` does, turns thirty rows of `0.4` cents into zero. `ROUND_HALF_UP` rather than
    banker's rounding because an invoice is not a statistical sample.
    """
    return int(total.quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def cents_from_dollars(amount: object) -> Decimal:
    """A JSON number of dollars → a `Decimal` of cents, without going through a float.

    `Decimal(str(x))` and never `Decimal(x)`: the JSON parser has already made `0.006` into a
    float, and `Decimal(0.006)` is `0.005999999999999999778...`. Stringifying first recovers
    the literal the vendor sent. Summing happens in `Decimal`; rounding happens once, in
    `cents_from_decimal`.
    """
    return Decimal(str(amount)) * 100


__all__ = [
    "ANTHROPIC_CONSOLE",
    "APPLE_CONSOLE",
    "FLY_CONSOLE",
    "GITHUB_CONSOLE",
    "LABELS",
    "NEON_CONSOLE",
    "RESEND_CONSOLE",
    "TIGRIS_CONSOLE",
    "bytes_binary",
    "bytes_decimal",
    "cents_from_decimal",
    "cents_from_dollars",
    "money",
    "tokens",
]
