"""Full-text search across an archive.

`GET /entries?q=` runs through here. It matches three things — the title you gave an entry,
the body you wrote, and the transcript the phone produced on device — and ranks the results
so the strongest match is first rather than merely the most recent.

**Why `websearch_to_tsquery`.** It is the only one of Postgres's query parsers that cannot
raise a syntax error on whatever a person types into a search box, and it understands the
two operators everybody already knows: `"exact phrase"` in quotes and `-excluded` with a
minus. `to_tsquery` would 500 on an unbalanced paren.

**What it does not do is prefix matching.** Typing `hangab` finds nothing; `hangaburgers`
finds "hangaburger", because both stem to the same lexeme. This is search-on-submit, not
search-as-you-type, and buying prefix matching would mean hand-assembling a tsquery out of
user input — the exact thing `websearch_to_tsquery` exists to avoid. See
docs/decisions-log.md.
"""

from __future__ import annotations

from sqlalchemy import ColumnElement, Double, cast, func, literal, select, union
from sqlalchemy.dialects.postgresql import ARRAY, REAL

from rascal.models import Entry, Media

# The text search configuration, named rather than left to `default_text_search_config`. A
# generated column's expression has to be IMMUTABLE, which the one-argument `to_tsvector` is
# not, and pinning it here means the query and the index always agree on what a lexeme is.
CONFIG = "english"

# ts_rank_cd's weight vector, in Postgres's order: {D, C, B, A}. Postgres defaults to
# {0.1, 0.2, 0.4, 1.0}. D is unused by either vector, and C — a machine-written caption — is
# pushed down so it never outranks something a person actually said or typed.
WEIGHTS = [0.05, 0.15, 0.5, 1.0]


def _weights() -> ColumnElement:
    # Cast explicitly: `ts_rank_cd` is overloaded on `real[]`, and an uncast bind parameter
    # picks the wrong overload rather than failing loudly.
    return cast(literal(WEIGHTS), ARRAY(REAL))


def tsquery(raw: str) -> ColumnElement:
    return func.websearch_to_tsquery(CONFIG, raw.strip())


def _media_rank(query: ColumnElement) -> ColumnElement:
    """The best-matching live media row under an entry, as a correlated scalar."""
    best = func.max(func.ts_rank_cd(_weights(), Media.search_vector, query))
    return (
        select(func.coalesce(best, 0.0))
        .where(Media.entry_id == Entry.id, Media.deleted_at.is_(None))
        .correlate(Entry)
        .scalar_subquery()
    )


def rank_expression(query: ColumnElement) -> ColumnElement:
    """How well an entry matches, counting its own text and its media's transcripts.

    Cast to `double precision` deliberately. `ts_rank_cd` returns `real`, and a float4 that
    round-trips out through a pagination cursor and back in as a float8 is not guaranteed to
    compare equal to itself — which would make the keyset comparison silently drop or repeat
    a row at every page boundary.
    """
    own = func.ts_rank_cd(_weights(), Entry.search_vector, query)
    return cast(own + _media_rank(query), Double)


def matches(query: ColumnElement) -> ColumnElement:
    """Entries whose own text matches, or that have a live media row whose text does.

    Written as a UNION of two id sets rather than as `entries.search_vector @@ q OR id IN
    (...)`. The OR form makes Postgres fall back to a sequential scan over `entries` — it
    cannot combine an index condition with a hashed subplan — while each arm of the UNION
    plans as its own bitmap index scan. Checked with EXPLAIN, not assumed.

    Ranking is deliberately not the filter. `rank > 0` would be equivalent and would defeat
    both indexes.
    """
    own = (
        select(Entry.id.label("entry_id"))
        .where(Entry.search_vector.bool_op("@@")(query))
        # Without this, SQLAlchemy auto-correlates against the enclosing `entries` and drops
        # the FROM clause, quietly turning this arm into a no-op.
        .correlate(None)
    )
    from_media = select(Media.entry_id.label("entry_id")).where(
        Media.search_vector.bool_op("@@")(query),
        Media.deleted_at.is_(None),
    )
    hits = union(own, from_media).subquery("search_hits")
    return Entry.id.in_(select(hits.c.entry_id))


# No `ts_headline` here on purpose. `EntryOut` already carries the full title and body, so
# the client has everything it needs to mark up its own snippet, and a server-rendered one
# would put HTML into a JSON API that a browser and a phone would style differently.
