"""On This Day."""

from __future__ import annotations

import datetime as dt
from typing import Literal

from pydantic import Field

from rascal.schemas.common import ApiModel
from rascal.schemas.entry import EntryOut


class MomentGroup(ApiModel):
    years_ago: int
    entries: list[EntryOut]


class MomentsResponse(ApiModel):
    """All four keys are always present.

    `docs/api-contract.md` describes the empty case as returning
    `{"fallback": "random", "entries": [...]}`. Rather than shipping two different shapes,
    the response always carries both: `groups` is filled on a hit, `entries` is filled on the
    warm redirect, and `fallback` says which happened. A typed client parses one model.
    """

    date: dt.date
    fallback: Literal["random"] | None = None
    groups: list[MomentGroup] = Field(default_factory=list)
    entries: list[EntryOut] = Field(default_factory=list)
