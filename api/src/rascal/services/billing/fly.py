"""The machine and volume inventory, which is the thing this project has actually been bitten by.

**Fly exposes no money at all over any public API** — not in the Machines OpenAPI description
and not in the GraphQL schema, which was searched type by type for an invoice, statement or
month-to-date query and has none. So there is no dollar figure here and none is invented.

What is here is more useful anyway: **which machines exist, how big each one is, which image
each is on, which of them carry a schedule, and what volumes are provisioned.** That is a
direct answer to the failure class `roadmap-status.md` names — *"a deploy that is green
everywhere and still does not reach the machine that does the work."* The scheduler machine sat
outside the process group for weeks, every deploy was green, and nothing in CI could see it.

Two cost drivers the machine list alone misses, both added here:

**Guest size.** A machine quietly scaled from 512 MB to 2 GB is a threefold line-item change
that no deploy, test or log surfaces. A machine whose guest differs from the majority is
flagged for exactly the same reason a stale image tag is.

**Volumes.** A volume bills on its provisioned size whether or not anything is attached to it,
so a detached volume is a bill for nothing, and it appears on no other screen.
"""

from __future__ import annotations

import asyncio
from typing import Any

import httpx

from rascal.config import Settings
from rascal.services.billing.base import Metric, ProviderReport, unconfigured
from rascal.services.billing.format import FLY_CONSOLE, LABELS

_SETUP = (
    "Set FLY_API_TOKEN (`fly tokens create readonly`) and FLY_APP_NAME. Read-only is enough — "
    "nothing here writes."
)

_DETAIL = (
    "Fly exposes no per-app spend over the API — there is no invoice or month-to-date query "
    "in the Machines API or in GraphQL. Machines, guests, volumes and schedules are what this "
    "card is for. A stopped machine is not free: it still bills its root filesystem, and the "
    "API does not report how large that is."
)


async def fly_report(client: httpx.AsyncClient, settings: Settings) -> ProviderReport:
    if not settings.fly_api_token:
        return unconfigured("fly", LABELS["fly"], _SETUP, FLY_CONSOLE)

    headers = {"Authorization": f"Bearer {settings.fly_api_token}"}
    base = f"https://api.machines.dev/v1/apps/{settings.fly_app_name}"
    # `summary=true` is deliberately not passed on the machines call: it returns `config: null`,
    # which would silently blank the image, the schedule and the guest — every field read here.
    machines_response, volumes_response = await asyncio.gather(
        client.get(f"{base}/machines", headers=headers),
        client.get(f"{base}/volumes", headers=headers),
        return_exceptions=True,
    )

    if isinstance(machines_response, BaseException):
        raise machines_response
    if machines_response.status_code != 200:
        return _error(machines_response.status_code, settings)

    machines: list[dict[str, Any]] = machines_response.json()
    metrics = _machine_metrics(machines)
    metrics.extend(_volume_metrics(volumes_response))

    return ProviderReport(
        key="fly",
        label=LABELS["fly"],
        status="ok",
        detail=_DETAIL,
        metrics=tuple(metrics),
        console_url=FLY_CONSOLE,
    )


def _error(status: int, settings: Settings) -> ProviderReport:
    """Three codes, three different fixes. The old card collapsed the first two and had no third.

    401 means the token is wrong, 403 means it belongs to another organisation, and 404 means
    the app name is. Sending somebody to regenerate a token when the app name is misspelled is
    a wasted afternoon.
    """
    detail = {
        401: (
            "401 from the Machines API. FLY_API_TOKEN is missing, malformed or expired — "
            "regenerate it with `fly tokens create readonly`."
        ),
        403: (
            "403 from the Machines API. The token is valid but belongs to a different "
            "organisation than this app."
        ),
        404: (
            f"404 from the Machines API — no app named {settings.fly_app_name!r}. "
            "FLY_APP_NAME is wrong, or the app is gone. The token is probably fine."
        ),
    }.get(status, f"HTTP {status} from the Machines API.")
    return ProviderReport(
        key="fly",
        label=LABELS["fly"],
        status="error",
        detail=detail,
        console_url=FLY_CONSOLE,
    )


def _guest(machine: dict[str, Any]) -> str | None:
    """`"shared-1x · 512 MB"`. `None` when the machine reports no guest block at all.

    Every field is read with `.get()`: `gpu_kind`, `gpus` and `max_memory_mb` are omitted from
    live responses when unset, and a missing `guest` is not an error worth failing the card for.
    """
    guest = (machine.get("config") or {}).get("guest") or {}
    if not guest:
        return None
    kind = str(guest.get("cpu_kind") or "?")
    cpus = guest.get("cpus") or "?"
    memory = guest.get("memory_mb")
    size = f"{kind}-{cpus}x"
    return f"{size} · {memory:,} MB" if isinstance(memory, int) else size


def _machine_metrics(machines: list[dict[str, Any]]) -> list[Metric]:
    images = [str(m.get("config", {}).get("image", "")) for m in machines]
    tags = [image.split("@", 1)[0] for image in images if image]
    majority_tag = max(set(tags), key=tags.count) if tags else ""

    guests = [g for g in (_guest(m) for m in machines) if g]
    majority_guest = max(set(guests), key=guests.count) if guests else ""

    metrics: list[Metric] = [
        Metric(
            label="Machines",
            value=str(len(machines)),
            detail=", ".join(sorted({str(m.get("region", "?")) for m in machines})) or None,
        )
    ]
    if majority_guest:
        same = sum(1 for g in guests if g == majority_guest)
        metrics.append(
            Metric(
                label="Guest",
                value=majority_guest,
                detail=f"{same} of {len(machines)} machine{'s' if len(machines) != 1 else ''}",
            )
        )

    drifted = 0
    for machine in machines:
        config = machine.get("config") or {}
        schedule = config.get("schedule")
        image_tag = str(config.get("image", "")).split("@", 1)[0]
        stale = bool(majority_tag) and image_tag != majority_tag
        drifted += stale
        if schedule:
            metrics.append(
                Metric(
                    label=f"scheduled · {schedule}",
                    value=str(machine.get("state", "?")),
                    detail=f"{machine.get('id', '?')} — image {'STALE' if stale else 'current'}",
                    tone="bad" if stale else "ok",
                )
            )
    if drifted:
        metrics.insert(
            1,
            Metric(
                label="Image drift",
                value=f"{drifted} machine{'s' if drifted != 1 else ''} behind",
                detail="A green deploy does not reach a machine outside the process group.",
                tone="bad",
            ),
        )

    odd = [
        m
        for m in machines
        if majority_guest and _guest(m) is not None and _guest(m) != majority_guest
    ]
    for machine in odd:
        metrics.append(
            Metric(
                label="Guest drift",
                value=str(_guest(machine)),
                detail=f"{machine.get('id', '?')} differs from the other machines — a size "
                "change is a line-item change and shows up on no other screen.",
                tone="bad",
            )
        )
    return metrics


def _volume_metrics(response: httpx.Response | BaseException) -> list[Metric]:
    """Volumes, or one honest line saying why there are none listed.

    The volumes call is not allowed to fail the card: the machine inventory is the card's
    actual job and a volumes outage should cost the volume rows, not the screen.
    """
    if isinstance(response, BaseException):
        return [
            Metric(
                label="Volumes",
                value="unreadable",
                detail="the volumes call did not complete",
                tone="warn",
            )
        ]
    if response.status_code != 200:
        return [
            Metric(
                label="Volumes",
                value="unreadable",
                detail=f"HTTP {response.status_code} from the volumes endpoint",
                tone="warn",
            )
        ]

    volumes: list[dict[str, Any]] = response.json() or []
    if not volumes:
        # An empty list is HTTP 200 `[]`, not a 404, so this really is "none provisioned".
        return [
            Metric(
                label="Volumes",
                value="none",
                detail="nothing provisioned. A volume bills on its size whether attached or not.",
            )
        ]

    metrics = [
        Metric(
            label="Volumes",
            value=f"{sum(int(v.get('size_gb') or 0) for v in volumes):,} GB",
            detail=f"{len(volumes)} volume{'s' if len(volumes) != 1 else ''}, provisioned size",
        )
    ]
    for volume in volumes:
        attached = volume.get("attached_machine_id")
        metrics.append(
            Metric(
                label=f"volume · {volume.get('name') or volume.get('id', '?')}",
                value=f"{int(volume.get('size_gb') or 0):,} GB",
                detail=f"{volume.get('region', '?')} · "
                + (f"attached to {attached}" if attached else "not attached, and still billed"),
                tone="plain" if attached else "warn",
            )
        )
    return metrics


__all__ = ["fly_report"]
