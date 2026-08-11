"""The five gaps the iOS lane was working around, and the behaviour that closes each.

Every test here corresponds to an entry that was open in `docs/blocked.md`: a client that had
built a screen against this API, found it could not say something, and shipped a workaround
rather than a patch to the backend. The workarounds are the specification — each test asserts
the thing the client wanted to be able to stop doing.
"""

from __future__ import annotations

import datetime as dt
import uuid

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import grant, make_assignment, make_child, make_prompt, make_user
from helpers import auth_headers
from rascal.models import Child, Entry


async def _world(session: AsyncSession, *, role: str = "parent"):
    user = await make_user(session)
    child = await make_child(session, birthdate=dt.date(2022, 6, 14))
    await grant(session, user, child, role)
    await session.commit()
    return user, child


def _entry_body(child: Child, **overrides) -> dict:
    body = {
        "id": str(uuid.uuid4()),
        "child_id": str(child.id),
        "occurred_at": "2026-08-14T18:22:00Z",
        "body": "Dear Hendrix,",
    }
    body.update(overrides)
    return body


# --- Sealing: an omitted key and an explicit null are different answers -------------------
#
# blocked.md: "Pydantic gives None for an omitted key and for an explicit null alike, so the
# handler cannot tell 'I have no opinion' from 'the parent turned this off'." The client
# worked around it by comparing what it sent with what came back and re-sending a PATCH.


async def test_omitting_unlock_at_age_seals_a_letter_at_the_prompt_default(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session, kind="letter", cadence="monthly", default_unlock_age=18)
    assignment = await make_assignment(session, child, prompt, slot="letter")
    await session.commit()

    response = await client.post(
        "/v1/entries",
        json=_entry_body(child, assignment_id=str(assignment.id)),
        headers=auth_headers(user),
    )

    assert response.status_code == 201
    # A client that has never heard of sealing still writes a sealed letter. This is the
    # default the server owns, and it must survive the fix.
    assert response.json()["unlock_at_age"] == 18


async def test_an_explicit_null_unlock_at_age_leaves_a_letter_unsealed(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session, kind="letter", cadence="monthly", default_unlock_age=18)
    assignment = await make_assignment(session, child, prompt, slot="letter")
    await session.commit()

    response = await client.post(
        "/v1/entries",
        json=_entry_body(child, assignment_id=str(assignment.id), unlock_at_age=None),
        headers=auth_headers(user),
    )

    assert response.status_code == 201
    # The whole point: the parent turned sealing off on a screen, and the archive agrees.
    assert response.json()["unlock_at_age"] is None
    stored = await session.get(Entry, uuid.UUID(response.json()["id"]))
    assert stored.unlock_at_age is None


async def test_an_explicit_unlock_age_still_wins_over_the_prompt_default(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session, kind="letter", cadence="monthly", default_unlock_age=18)
    assignment = await make_assignment(session, child, prompt, slot="letter")
    await session.commit()

    response = await client.post(
        "/v1/entries",
        json=_entry_body(child, assignment_id=str(assignment.id), unlock_at_age=21),
        headers=auth_headers(user),
    )

    assert response.status_code == 201
    assert response.json()["unlock_at_age"] == 21


async def test_sync_push_honours_an_explicit_null_unlock_at_age(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The worse of the two routes to get wrong: nobody is watching when it arrives.

    A letter written on a plane with sealing deliberately off reaches the server hours later
    through `/sync/push`, with the parent long gone from the screen that said so.
    """
    user, child = await _world(session)
    prompt = await make_prompt(session, kind="letter", cadence="monthly", default_unlock_age=18)
    assignment = await make_assignment(session, child, prompt, slot="letter")
    await session.commit()

    record_id = str(uuid.uuid4())
    response = await client.post(
        "/v1/sync/push",
        json={
            "child_id": str(child.id),
            "entries": [
                {
                    "id": record_id,
                    "child_id": str(child.id),
                    "assignment_id": str(assignment.id),
                    "occurred_at": "2026-08-14T18:22:00Z",
                    "body": "written offline, deliberately unsealed",
                    "unlock_at_age": None,
                }
            ],
            "media": [],
            "idempotency_keys": {record_id: str(uuid.uuid4())},
        },
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    stored = await session.get(Entry, uuid.UUID(record_id))
    assert stored.unlock_at_age is None


async def test_sync_push_without_the_key_still_seals(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session, kind="letter", cadence="monthly", default_unlock_age=18)
    assignment = await make_assignment(session, child, prompt, slot="letter")
    await session.commit()

    record_id = str(uuid.uuid4())
    response = await client.post(
        "/v1/sync/push",
        json={
            "child_id": str(child.id),
            "entries": [
                {
                    "id": record_id,
                    "child_id": str(child.id),
                    "assignment_id": str(assignment.id),
                    "occurred_at": "2026-08-14T18:22:00Z",
                    "body": "no opinion about sealing",
                }
            ],
            "media": [],
            "idempotency_keys": {record_id: str(uuid.uuid4())},
        },
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    stored = await session.get(Entry, uuid.UUID(record_id))
    assert stored.unlock_at_age == 18


# --- prompt_body on a list row -----------------------------------------------------------
#
# blocked.md: "EntryOut has no prompt; only EntryDetail does. The v3 card leads with the
# prompt the entry answered, so on a list row there was nothing to quote."


async def test_the_timeline_carries_the_prompt_each_entry_answered(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    prompt = await make_prompt(session, body="What did he call the moon tonight?")
    assignment = await make_assignment(session, child, prompt)
    await session.commit()

    await client.post(
        "/v1/entries",
        json=_entry_body(child, assignment_id=str(assignment.id)),
        headers=auth_headers(user),
    )
    listing = await client.get(
        "/v1/entries", params={"child_id": str(child.id)}, headers=auth_headers(user)
    )

    assert listing.status_code == 200
    assert listing.json()["entries"][0]["prompt_body"] == "What did he call the moon tonight?"


async def test_a_freeform_entry_has_no_prompt_body(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)

    await client.post("/v1/entries", json=_entry_body(child), headers=auth_headers(user))
    listing = await client.get(
        "/v1/entries", params={"child_id": str(child.id)}, headers=auth_headers(user)
    )

    # Null rather than "", so a card can drop the quote zone instead of rendering an empty one.
    assert listing.json()["entries"][0]["prompt_body"] is None


async def test_a_parent_authored_custom_body_wins_over_the_library_prompt(
    client: AsyncClient, session: AsyncSession
) -> None:
    """`resolved_body`, not `prompts.body` — quote what was actually on screen."""
    user, child = await _world(session)
    prompt = await make_prompt(session, body="the library's wording")
    assignment = await make_assignment(
        session, child, prompt, custom_body="what his dad actually asked"
    )
    await session.commit()

    await client.post(
        "/v1/entries",
        json=_entry_body(child, assignment_id=str(assignment.id)),
        headers=auth_headers(user),
    )
    listing = await client.get(
        "/v1/entries", params={"child_id": str(child.id)}, headers=auth_headers(user)
    )

    assert listing.json()["entries"][0]["prompt_body"] == "what his dad actually asked"


async def test_sync_serializes_entries_with_the_same_eager_loads_as_the_timeline(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The regression guard for `loaded()`.

    `/sync` selects entries itself and serializes them with `to_entry_out`. It used to restate
    the eager-load list by hand, so every field that function learned to read had to be
    remembered in two places. `Entry.assignment` is `lazy="raise"`, which turns a miss into a
    500 on the sync path only — invisible to every timeline test.
    """
    user, child = await _world(session)
    prompt = await make_prompt(session, body="the sentence sync has to carry")
    assignment = await make_assignment(session, child, prompt)
    await session.commit()

    await client.post(
        "/v1/entries",
        json=_entry_body(child, assignment_id=str(assignment.id)),
        headers=auth_headers(user),
    )
    pulled = await client.get(
        "/v1/sync", params={"child_id": str(child.id)}, headers=auth_headers(user)
    )

    assert pulled.status_code == 200
    assert pulled.json()["entries"][0]["prompt_body"] == "the sentence sync has to carry"


# --- ?sealed= ----------------------------------------------------------------------------
#
# blocked.md: "Sealed is unlock_at_age IS NOT NULL, not an entry_type, so ?type= cannot
# express it." The client paged the whole archive and filtered locally, bounded to ten pages.


async def _one_sealed_and_one_not(client: AsyncClient, user, child) -> None:
    await client.post(
        "/v1/entries",
        json=_entry_body(child, body="a sealed letter", unlock_at_age=18),
        headers=auth_headers(user),
    )
    await client.post(
        "/v1/entries",
        json=_entry_body(child, body="an ordinary note", unlock_at_age=None),
        headers=auth_headers(user),
    )


async def test_sealed_true_returns_only_sealed_entries(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    await _one_sealed_and_one_not(client, user, child)

    listing = await client.get(
        "/v1/entries",
        params={"child_id": str(child.id), "sealed": "true"},
        headers=auth_headers(user),
    )

    bodies = [entry["body"] for entry in listing.json()["entries"]]
    assert bodies == ["a sealed letter"]


async def test_sealed_false_returns_only_unsealed_entries(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    await _one_sealed_and_one_not(client, user, child)

    listing = await client.get(
        "/v1/entries",
        params={"child_id": str(child.id), "sealed": "false"},
        headers=auth_headers(user),
    )

    bodies = [entry["body"] for entry in listing.json()["entries"]]
    assert bodies == ["an ordinary note"]


async def test_omitting_sealed_returns_both(client: AsyncClient, session: AsyncSession) -> None:
    user, child = await _world(session)
    await _one_sealed_and_one_not(client, user, child)

    listing = await client.get(
        "/v1/entries", params={"child_id": str(child.id)}, headers=auth_headers(user)
    )

    assert len(listing.json()["entries"]) == 2


async def test_the_sealed_filter_narrows_search_too(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Search and the timeline share `_filters`, so a filter that only worked on one would be
    a quiet asymmetry — the Sealed chip and the search field are usable together."""
    user, child = await _world(session)
    await client.post(
        "/v1/entries",
        json=_entry_body(child, body="hangaburger, sealed", unlock_at_age=18),
        headers=auth_headers(user),
    )
    await client.post(
        "/v1/entries",
        json=_entry_body(child, body="hangaburger, open"),
        headers=auth_headers(user),
    )

    listing = await client.get(
        "/v1/entries",
        params={"child_id": str(child.id), "q": "hangaburger", "sealed": "true"},
        headers=auth_headers(user),
    )

    bodies = [entry["body"] for entry in listing.json()["entries"]]
    assert bodies == ["hangaburger, sealed"]


# --- The child avatar --------------------------------------------------------------------
#
# blocked.md: "children.avatar_key exists and PATCH accepts it, so the destination is
# modelled. Nothing mints a key." The client kept avatars on the device, so they did not
# survive a new phone.


async def test_presigning_an_avatar_returns_a_key_and_stores_nothing(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)

    response = await client.post(
        f"/v1/children/{child.id}/avatar-upload-url",
        json={"content_type": "image/jpeg", "bytes": 41234},
        headers=auth_headers(user),
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["avatar_key"].startswith(f"children/{child.id}/avatar/")
    assert payload["avatar_key"].endswith(".jpg")
    assert payload["upload_url"]
    assert payload["expires_in"] > 0

    # Nothing is committed until the client PATCHes the key back. A presign the phone
    # abandons must not leave a child pointing at bytes that never arrived.
    await session.refresh(child)
    assert child.avatar_key is None


async def test_two_presigns_never_reuse_a_key(client: AsyncClient, session: AsyncSession) -> None:
    """A stable `avatar.jpg` would make a replaced avatar indistinguishable from a corrupted
    one, because every cached copy and every URL in flight would follow the overwrite."""
    user, child = await _world(session)

    first = await client.post(
        f"/v1/children/{child.id}/avatar-upload-url",
        json={"content_type": "image/jpeg", "bytes": 1000},
        headers=auth_headers(user),
    )
    second = await client.post(
        f"/v1/children/{child.id}/avatar-upload-url",
        json={"content_type": "image/jpeg", "bytes": 1000},
        headers=auth_headers(user),
    )

    assert first.json()["avatar_key"] != second.json()["avatar_key"]


async def test_an_avatar_presign_refuses_a_content_type_it_cannot_name(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)

    response = await client.post(
        f"/v1/children/{child.id}/avatar-upload-url",
        json={"content_type": "application/pdf", "bytes": 1000},
        headers=auth_headers(user),
    )

    assert response.status_code == 422
    assert response.json()["error"]["field"] == "content_type"


async def test_an_avatar_presign_refuses_a_full_resolution_original(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)

    response = await client.post(
        f"/v1/children/{child.id}/avatar-upload-url",
        json={"content_type": "image/jpeg", "bytes": 40 * 1024 * 1024},
        headers=auth_headers(user),
    )

    assert response.status_code == 422
    assert response.json()["error"]["field"] == "bytes"


async def test_the_avatar_url_is_404_until_a_key_is_patched_on(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Not a null URL. "No avatar" and "a URL that will not resolve" are different answers,
    and only the first lets a client fall back to initials without a failing round trip."""
    user, child = await _world(session)

    missing = await client.get(f"/v1/children/{child.id}/avatar-url", headers=auth_headers(user))
    assert missing.status_code == 404

    presigned = await client.post(
        f"/v1/children/{child.id}/avatar-upload-url",
        json={"content_type": "image/jpeg", "bytes": 41234},
        headers=auth_headers(user),
    )
    await client.patch(
        f"/v1/children/{child.id}",
        json={"avatar_key": presigned.json()["avatar_key"]},
        headers=auth_headers(user),
    )

    found = await client.get(f"/v1/children/{child.id}/avatar-url", headers=auth_headers(user))
    assert found.status_code == 200
    assert found.json()["url"]


async def test_a_viewer_can_read_an_avatar_but_not_presign_one(
    client: AsyncClient, session: AsyncSession
) -> None:
    """Anyone who can see the child can see their face; only a parent can replace it."""
    parent, child = await _world(session)
    viewer = await make_user(session)
    await grant(session, viewer, child, "viewer")
    await session.commit()

    presigned = await client.post(
        f"/v1/children/{child.id}/avatar-upload-url",
        json={"content_type": "image/jpeg", "bytes": 41234},
        headers=auth_headers(parent),
    )
    await client.patch(
        f"/v1/children/{child.id}",
        json={"avatar_key": presigned.json()["avatar_key"]},
        headers=auth_headers(parent),
    )

    assert (
        await client.get(f"/v1/children/{child.id}/avatar-url", headers=auth_headers(viewer))
    ).status_code == 200
    assert (
        await client.post(
            f"/v1/children/{child.id}/avatar-upload-url",
            json={"content_type": "image/jpeg", "bytes": 41234},
            headers=auth_headers(viewer),
        )
    ).status_code == 403


# --- children.pronouns -------------------------------------------------------------------
#
# decisions.md open item 10, blocked since onboarding shipped: "Asking for pronouns and then
# discarding them would be worse than not asking, so onboarding does not ask."


async def test_a_child_is_created_without_pronouns_because_unanswered_is_not_they_them(
    client: AsyncClient, session: AsyncSession
) -> None:
    user = await make_user(session)
    await session.commit()

    response = await client.post(
        "/v1/children",
        json={
            "name": "Hendrix",
            "birthdate": "2021-04-04",
            "family_timezone": "America/Detroit",
        },
        headers=auth_headers(user),
    )

    assert response.status_code == 201
    # Null, not a default. A parent who skipped the question has said nothing, and prompt
    # rendering has to be able to tell that from an answer.
    assert response.json()["pronouns"] is None


async def test_a_child_can_be_created_with_pronouns(
    client: AsyncClient, session: AsyncSession
) -> None:
    user = await make_user(session)
    await session.commit()

    response = await client.post(
        "/v1/children",
        json={
            "name": "Hendrix",
            "birthdate": "2021-04-04",
            "pronouns": "they/them",
            "family_timezone": "America/Detroit",
        },
        headers=auth_headers(user),
    )

    assert response.status_code == 201
    assert response.json()["pronouns"] == "they/them"


async def test_pronouns_can_be_set_and_then_cleared(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)

    set_it = await client.patch(
        f"/v1/children/{child.id}", json={"pronouns": "she/her"}, headers=auth_headers(user)
    )
    assert set_it.json()["pronouns"] == "she/her"

    # An explicit null gets back to unanswered — the router dumps with exclude_unset, so this
    # is a field that was set to null rather than a field that was omitted.
    cleared = await client.patch(
        f"/v1/children/{child.id}", json={"pronouns": None}, headers=auth_headers(user)
    )
    assert cleared.json()["pronouns"] is None


async def test_an_unknown_pronoun_set_is_refused(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)

    response = await client.patch(
        f"/v1/children/{child.id}",
        json={"pronouns": "xe/xem"},
        headers=auth_headers(user),
    )

    # A closed set, per the constrained-value convention: pronoun substitution has to
    # enumerate the forms it writes, and storing text nothing can render is not recoverable.
    assert response.status_code == 422


async def test_the_children_list_carries_pronouns(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _world(session)
    await client.patch(
        f"/v1/children/{child.id}", json={"pronouns": "he/him"}, headers=auth_headers(user)
    )

    listing = await client.get("/v1/children", headers=auth_headers(user))

    assert listing.json()[0]["pronouns"] == "he/him"
