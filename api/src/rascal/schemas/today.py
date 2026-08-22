"""The single call the home screen makes, plus the assignment actions it can take."""

from __future__ import annotations

import datetime as dt
import uuid

from pydantic import Field

from rascal.constants import AccessState, AssignmentStatus, Slot
from rascal.schemas.child import ChildSummary
from rascal.schemas.common import ApiModel


class AssignmentOut(ApiModel):
    id: uuid.UUID
    slot: Slot
    # A parent-authored custom_body wins over the library prompt it replaced.
    body: str
    kind: str
    completion_mode: str
    theme: str | None
    status: AssignmentStatus
    assigned_on: dt.date
    expires_on: dt.date
    prompt_id: uuid.UUID | None
    is_custom: bool
    unlock_at_age: int | None = None


class LockedSlot(ApiModel):
    """A slot this day holds that the household may not have.

    **Two fields, and the absence of every other one is the design.** There is no `id`, no
    `body`, no `prompt_id` and no `theme` — this is the *shape* of the thing, not a teaser for
    it. Three reasons, and any one of them is sufficient:

    * Naming the prompt would mean **picking** one, and a pick writes an assignment and burns
      the 180-day cooldown against a 133-prompt pool. The whole point of the gate is not to
      spend a free household's runway on prompts they cannot answer.
    * D7 calls the mission library the one asset in this project a competitor would actually
      want. A paywall that serves the copy it is withholding is not a paywall.
    * A client decoding `AssignmentOut` requires an `id`. Keeping locked items in their own
      list with their own type is what lets that decoder stay strict.
    """

    slot: Slot
    #: What sort of thing the slot would have held, for a client choosing a glyph. `photo` for
    #: `mission`; `mission` for `mission_b`, deliberately vague because its pool spans video,
    #: audio and activity and which one a day would have produced is unknowable without the
    #: pick this endpoint is avoiding; `weekly`, `monthly` and `letter` for the shared slots.
    #: **A client should render an unrecognised hint as a generic locked row rather than
    #: dropping it** — the set can grow.
    kind_hint: str


class TodayResponse(ApiModel):
    date: dt.date
    child: ChildSummary
    #: What this household may reach: `subscribed` | `trial` | `free`. **The same value
    #: `GET /families/me` reports, from the same function** — `services/guardians.access_for`,
    #: the one authority. Not a fourth opinion about whether somebody has paid.
    access: AccessState
    #: When the trial runs out; null means no trial on this household. Carried for copy only.
    #: **A client must never compute entitlement from it** — the device never decides, per D5.
    trial_ends_at: dt.datetime | None = None
    today: list[AssignmentOut]
    #: The slots today holds that this household may not have. **`[]` for an entitled
    #: household — never absent, never null**, so a client has one shape to decode rather than
    #: two, and "no lock" is a value rather than an inference from a missing key.
    #:
    #: **A locked slot never appears in `waiting`** — it was never offered, so it cannot be
    #: missed, and the exclusion is in the query rather than in the absence of rows.
    #:
    #: ~~and is never expired against the parent~~ — **struck Aug 22, 2026: a hidden row does
    #: still expire**, on the same fourteen-day clock as any other, because `_expire_stale` has
    #: no entitlement filter. Suppressing that was considered and rejected: a household that
    #: lapses for a year and returns would find a year-old mission in `waiting`, which is the
    #: infinite backlog *"items stack; expire at 14 days"* exists to prevent. **A household that
    #: returns inside the window gets the row back with the days it has left**, which is the
    #: case that matters and is what not deleting it buys.
    #:
    #: This sentence was corrected in `docs/api-contract.md` first and lived on here for a
    #: commit — a claim worth striking is worth striking everywhere it was written.
    locked: list[LockedSlot] = Field(default_factory=list)
    # Pending assignments from previous days, oldest first. Backlog is fine; guilt is not.
    waiting: list[AssignmentOut] = Field(default_factory=list)
    #: **Never filtered by entitlement, and that is deliberate.** `done_today` is work this
    #: household already did; a parent who completed a mission this morning and lapsed at 2pm
    #: must not watch it disappear off their own board. The narrowing of D3 is that the day is
    #: locked and the archive never is — hiding a finished entry would be locking the archive.
    done_today: list[AssignmentOut] = Field(default_factory=list)


class CustomAssignmentRequest(ApiModel):
    body: str = Field(min_length=1, max_length=2000)
