"""Full-text search.

The point of this feature is a specific moment: it is 2038, there are four thousand entries,
and you remember he said something about a hangaburger. The tests below are that moment,
plus the ones that make it trustworthy — the transcript path, the ranking, the pagination
boundary, and the rows that must never come back.
"""

from __future__ import annotations

import datetime as dt
import uuid

import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.dialects import postgresql
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_child, make_user
from helpers import auth_headers
from rascal.models import Entry, Media
from rascal.services import entries as entries_service


async def _seed(session: AsyncSession) -> dict:
    user = await make_user(session)
    child = await make_child(session)
    await grant(session, user, child, "parent")

    made: dict[str, Entry] = {}
    rows = [
        ("hangaburger", "Hangaburger", "He asked for a hangaburger and I did not correct him."),
        ("moon", None, "He decided the moon was following the car all the way home."),
        ("running", "Sports day", "He would not stop running until he fell over."),
        ("bath", "Bath", "Refused the bath, then refused to get out of the bath."),
        ("nothing", None, "A perfectly ordinary Tuesday with nothing in it at all."),
    ]
    for index, (key, title, body) in enumerate(rows):
        entry = Entry(
            id=uuid.uuid4(),
            child_id=child.id,
            author_id=user.id,
            occurred_at=dt.datetime(2026, 3, 1 + index, 12, 0, tzinfo=dt.UTC),
            child_age_months=45 + index,
            title=title,
            body=body,
            entry_type="text",
        )
        session.add(entry)
        made[key] = entry
    await session.commit()
    return {"user": user, "child": child, "entries": made}


async def _search(client: AsyncClient, world: dict, q: str, **params) -> list[dict]:
    response = await client.get(
        "/v1/entries",
        params={"child_id": str(world["child"].id), "q": q, **params},
        headers=auth_headers(world["user"]),
    )
    assert response.status_code == 200, response.text
    return response.json()["entries"]


async def test_a_word_from_the_body_finds_the_entry(
    client: AsyncClient, session: AsyncSession
) -> None:
    world = await _seed(session)
    found = await _search(client, world, "hangaburger")
    assert [row["id"] for row in found] == [str(world["entries"]["hangaburger"].id)]


async def test_search_is_stemmed_so_a_different_tense_still_finds_it(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Searching "run" finds "running". This is the whole reason it is not an ILIKE.

    Stemming, not lemmatisation: "run" finds "running" and "runs", but not "ran". Postgres's
    Snowball stemmer chops suffixes, it does not know irregular verbs.
    """
    world = await _seed(session)
    found = await _search(client, world, "run")
    assert [row["id"] for row in found] == [str(world["entries"]["running"].id)]


async def test_a_quoted_phrase_is_a_phrase_and_not_two_words(
    client: AsyncClient, session: AsyncSession
) -> None:
    world = await _seed(session)
    assert await _search(client, world, '"moon was following"')
    # The same words, wrong order: present in the entry, absent as a phrase.
    assert await _search(client, world, '"following was moon"') == []


async def test_a_minus_excludes(client: AsyncClient, session: AsyncSession) -> None:
    world = await _seed(session)
    assert len(await _search(client, world, "bath")) == 1
    assert await _search(client, world, "bath -refused") == []


async def test_a_title_hit_outranks_a_body_hit(client: AsyncClient, session: AsyncSession) -> None:
    """A word in the title you chose is a stronger signal than one buried in the body."""
    world = await _seed(session)
    user, child = world["user"], world["child"]

    in_body = Entry(
        id=uuid.uuid4(),
        child_id=child.id,
        author_id=user.id,
        occurred_at=dt.datetime(2026, 4, 1, tzinfo=dt.UTC),
        child_age_months=46,
        body="We went to the aquarium and he was unmoved by every single fish.",
        entry_type="text",
    )
    in_title = Entry(
        id=uuid.uuid4(),
        child_id=child.id,
        author_id=user.id,
        # Deliberately older, so recency cannot be what puts it first.
        occurred_at=dt.datetime(2026, 1, 1, tzinfo=dt.UTC),
        child_age_months=43,
        title="Aquarium",
        body="Nothing much happened.",
        entry_type="text",
    )
    session.add_all([in_body, in_title])
    await session.commit()

    found = await _search(client, world, "aquarium")
    assert [row["id"] for row in found] == [str(in_title.id), str(in_body.id)]


async def test_equally_ranked_results_come_back_newest_first(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Relevance first, then the timeline's own order. Ties must not be arbitrary."""
    world = await _seed(session)
    user, child = world["user"], world["child"]
    ids = []
    for day in (5, 15, 25):
        entry = Entry(
            id=uuid.uuid4(),
            child_id=child.id,
            author_id=user.id,
            occurred_at=dt.datetime(2026, 6, day, tzinfo=dt.UTC),
            child_age_months=48,
            body="Pancakes.",
            entry_type="text",
        )
        session.add(entry)
        ids.append(entry.id)
    await session.commit()

    found = await _search(client, world, "pancakes")
    assert [row["id"] for row in found] == [str(i) for i in reversed(ids)]


async def test_a_transcript_written_back_from_the_phone_becomes_searchable(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Rule 7, end to end: PATCH /media/{id}/derived, then find the entry by what he said.

    The entry itself contains none of these words. Only the transcript does.
    """
    world = await _seed(session)
    user, child = world["user"], world["child"]

    entry = Entry(
        id=uuid.uuid4(),
        child_id=child.id,
        author_id=user.id,
        occurred_at=dt.datetime(2026, 5, 5, tzinfo=dt.UTC),
        child_age_months=47,
        entry_type="audio",
    )
    session.add(entry)
    await session.flush()
    media = Media(
        id=uuid.uuid4(),
        entry_id=entry.id,
        s3_key="children/x/story.m4a",
        kind="audio",
        bytes=900_000,
        upload_status="complete",
    )
    session.add(media)
    await session.commit()

    assert await _search(client, world, "brachiosaurus") == []

    response = await client.patch(
        f"/v1/media/{media.id}/derived",
        json={"transcript": "and then the brachiosaurus ate the whole entire tree"},
        headers=auth_headers(user),
    )
    assert response.status_code == 200, response.text

    found = await _search(client, world, "brachiosaurus")
    assert [row["id"] for row in found] == [str(entry.id)]


async def test_a_deleted_media_row_stops_matching(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Soft-deleting the audio has to take its words out of search with it."""
    world = await _seed(session)
    user, child = world["user"], world["child"]

    entry = Entry(
        id=uuid.uuid4(),
        child_id=child.id,
        author_id=user.id,
        occurred_at=dt.datetime(2026, 5, 6, tzinfo=dt.UTC),
        child_age_months=47,
        entry_type="audio",
    )
    session.add(entry)
    await session.flush()
    media = Media(
        id=uuid.uuid4(),
        entry_id=entry.id,
        s3_key="children/x/gone.m4a",
        kind="audio",
        bytes=1,
        upload_status="complete",
        transcript="the pterodactyl went to the shops",
    )
    session.add(media)
    await session.commit()

    assert len(await _search(client, world, "pterodactyl")) == 1

    media.deleted_at = dt.datetime.now(tz=dt.UTC)
    await session.commit()

    assert await _search(client, world, "pterodactyl") == []


async def test_search_never_returns_a_deleted_entry(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Every read path but /sync filters deleted_at IS NULL. Search is a read path."""
    world = await _seed(session)
    target = world["entries"]["hangaburger"]
    target.deleted_at = dt.datetime.now(tz=dt.UTC)
    await session.commit()

    assert await _search(client, world, "hangaburger") == []


async def test_search_never_crosses_into_another_childs_archive(
    client: AsyncClient, session: AsyncSession
) -> None:
    world = await _seed(session)
    other_user = await make_user(session)
    other_child = await make_child(session, name="Someone Else")
    await grant(session, other_user, other_child, "parent")
    session.add(
        Entry(
            id=uuid.uuid4(),
            child_id=other_child.id,
            author_id=other_user.id,
            occurred_at=dt.datetime(2026, 3, 9, tzinfo=dt.UTC),
            child_age_months=40,
            body="A hangaburger in a completely different family.",
            entry_type="text",
        )
    )
    await session.commit()

    found = await _search(client, world, "hangaburger")
    assert [row["id"] for row in found] == [str(world["entries"]["hangaburger"].id)]

    # And the guardian check still owns the door.
    response = await client.get(
        "/v1/entries",
        params={"child_id": str(other_child.id), "q": "hangaburger"},
        headers=auth_headers(world["user"]),
    )
    assert response.status_code == 403


async def test_search_pages_without_dropping_or_repeating_a_row(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Ranked keyset pagination. Rank ties are the common case, not the edge case."""
    world = await _seed(session)
    user, child = world["user"], world["child"]
    expected = []
    for day in range(1, 13):
        entry = Entry(
            id=uuid.uuid4(),
            child_id=child.id,
            author_id=user.id,
            occurred_at=dt.datetime(2026, 9, day, tzinfo=dt.UTC),
            child_age_months=50,
            body="Another swimming lesson.",
            entry_type="text",
        )
        session.add(entry)
        expected.append(entry.id)
    await session.commit()
    expected = [str(i) for i in reversed(expected)]

    seen: list[str] = []
    cursor = None
    for _ in range(10):  # bounded, so a broken cursor loops forever in the assert not the CI
        params = {"child_id": str(child.id), "q": "swimming", "limit": 5}
        if cursor:
            params["cursor"] = cursor
        response = await client.get("/v1/entries", params=params, headers=auth_headers(user))
        assert response.status_code == 200, response.text
        page = response.json()
        seen.extend(row["id"] for row in page["entries"])
        cursor = page["next_cursor"]
        if cursor is None:
            break

    assert cursor is None
    assert seen == expected
    assert len(seen) == len(set(seen))


async def test_a_timeline_cursor_is_not_valid_in_search(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The two modes order by different things. A cursor from one is meaningless in the other,
    and saying so beats returning a quietly wrong page."""
    world = await _seed(session)
    timeline = await client.get(
        "/v1/entries",
        params={"child_id": str(world["child"].id), "limit": 1},
        headers=auth_headers(world["user"]),
    )
    cursor = timeline.json()["next_cursor"]
    assert cursor

    response = await client.get(
        "/v1/entries",
        params={"child_id": str(world["child"].id), "q": "he", "cursor": cursor},
        headers=auth_headers(world["user"]),
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_failed"


async def test_search_composes_with_the_other_filters(
    client: AsyncClient, session: AsyncSession
) -> None:
    world = await _seed(session)
    assert await _search(client, world, "hangaburger", type="audio") == []
    assert len(await _search(client, world, "hangaburger", type="text")) == 1
    assert await _search(client, world, "hangaburger", after="2026-06-01T00:00:00Z") == []


async def test_an_empty_or_whitespace_q_is_the_plain_timeline(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A cleared search box must not return zero results."""
    world = await _seed(session)
    for blank in ("", "   "):
        found = await _search(client, world, blank)
        assert len(found) == 5


async def test_a_query_of_only_stopwords_finds_nothing_rather_than_everything(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Postgres drops stopwords, leaving an empty tsquery. Zero results is the honest answer."""
    world = await _seed(session)
    assert await _search(client, world, "the and of") == []


async def test_punctuation_that_would_break_to_tsquery_is_just_a_search(
    client: AsyncClient, session: AsyncSession
) -> None:
    """websearch_to_tsquery cannot be made to raise. A search box gets typed into."""
    world = await _seed(session)
    for hostile in ("(((", "!!!", "a & | b", "'", '"unclosed', ":*"):
        response = await client.get(
            "/v1/entries",
            params={"child_id": str(world["child"].id), "q": hostile},
            headers=auth_headers(world["user"]),
        )
        assert response.status_code == 200, f"{hostile!r} -> {response.text}"


async def test_both_gin_indexes_are_reachable_from_the_real_query(
    session: AsyncSession,
) -> None:
    """EXPLAIN the statement the service actually builds, not a hand-written approximation.

    `entries.search_vector @@ q OR id IN (...)` returns exactly the same rows as the UNION
    form and cannot use the entries index — Postgres will not combine an index condition
    with a hashed subplan. That regression is invisible until the archive is large enough
    to hurt, which is precisely too late, so it is asserted here instead.

    `enable_seqscan = off` because the test database holds a handful of rows and a sequential
    scan is genuinely cheaper; turning it off asks the planner whether it *could* use the
    index, which is the question.
    """
    world = await _seed(session)
    statement = entries_service.search_statement(world["child"].id, query="hangaburger")
    compiled = statement.compile(dialect=postgresql.dialect(paramstyle="pyformat"))

    connection = await session.connection()
    await connection.exec_driver_sql("SET LOCAL enable_seqscan = off")
    result = await connection.exec_driver_sql(f"EXPLAIN {compiled}", dict(compiled.params))
    plan = "\n".join(row[0] for row in result)

    assert "ix_entries_search_vector" in plan, plan
    assert "ix_media_search_vector" in plan, plan


async def test_the_generated_vectors_are_maintained_by_postgres_not_by_us(
    session: AsyncSession,
) -> None:
    """Stored generated columns, so there is no window where a row is written and the vector
    is not. Nothing in application code sets these — an UPDATE alone has to move them."""
    world = await _seed(session)
    entry = world["entries"]["moon"]

    vector = await session.scalar(
        sa.text("SELECT search_vector::text FROM entries WHERE id = :id"), {"id": entry.id}
    )
    assert "moon" in vector

    await session.execute(
        sa.text("UPDATE entries SET body = :body WHERE id = :id"),
        {"body": "He decided the streetlights were following the car.", "id": entry.id},
    )
    await session.commit()

    vector = await session.scalar(
        sa.text("SELECT search_vector::text FROM entries WHERE id = :id"), {"id": entry.id}
    )
    assert "moon" not in vector
    assert "streetlight" in vector  # stemmed on the way in, as the index expects

    # And the weights are the ones the ranking depends on: A for title, B for body.
    weighted = await session.scalar(
        sa.text("SELECT search_vector::text FROM entries WHERE id = :id"),
        {"id": world["entries"]["hangaburger"].id},
    )
    assert "'hangaburg':1A" in weighted
