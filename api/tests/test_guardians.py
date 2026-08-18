"""The household, the invite, and per-parent daily assignment. Phase 36.

The scheduler half is the part worth the most attention: `test_scheduler.py` covers the
single-guardian behaviour that must not have changed, and the tests here cover the second
guardian that is new.
"""

from __future__ import annotations

import asyncio
import datetime as dt

import sqlalchemy as sa
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from factories import grant, make_child, make_family, make_prompt, make_user
from helpers import auth_headers
from rascal.errors import ErrorCode, RascalError
from rascal.models import Assignment, Guardian, GuardianInvite, User
from rascal.services.guardians import accept_invite, hash_token
from rascal.services.scheduler import run_scheduler

TUESDAY = dt.date(2026, 8, 18)  # future-date: explicit, pure
SATURDAY = dt.date(2026, 8, 22)  # future-date: explicit, pure


async def _subscribed_parent(session: AsyncSession) -> tuple[User, object]:
    family = await make_family(session, tier="subscribed")
    user = await make_user(session, family=family)
    child = await make_child(session, parent=user)
    await session.commit()
    return user, child


# --- The entitlement gate ----------------------------------------------------------------


async def test_a_free_household_cannot_invite_a_second_parent(
    client: AsyncClient, session: AsyncSession
) -> None:
    """402, not 403. They are allowed to do this; they have not bought it yet."""
    user = await make_user(session)  # free by default
    await session.commit()

    response = await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))

    assert response.status_code == 402
    assert response.json()["error"]["code"] == "subscription_required"


async def test_the_402_body_names_what_subscribing_unlocks(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A door rather than a wall — no scolding, no countdown, no red."""
    user = await make_user(session)
    await session.commit()

    body = (
        await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))
    ).json()["error"]["message"]

    assert "Subscribing" in body
    for forbidden in ("upgrade now", "expired", "locked", "denied", "!"):
        assert forbidden not in body


async def test_a_subscribed_household_can_invite(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, _ = await _subscribed_parent(session)

    response = await client.post(
        "/v1/families/me/invites",
        json={"email": "Anna@Example.com"},
        headers=auth_headers(user),
    )

    assert response.status_code == 201
    assert response.json()["token"]
    # Recorded lowercased; nothing in this phase sends to it.
    assert response.json()["email"] == "anna@example.com"


async def test_the_raw_token_is_never_stored(client: AsyncClient, session: AsyncSession) -> None:
    """Only the SHA-256. A database dump cannot hand somebody a key to an archive."""
    user, _ = await _subscribed_parent(session)

    token = (
        await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))
    ).json()["token"]

    stored = await session.scalar(sa.select(GuardianInvite.token_hash))
    assert stored != token
    assert stored == hash_token(token)


async def test_a_household_of_two_refuses_a_third(
    client: AsyncClient, session: AsyncSession
) -> None:
    family = await make_family(session, tier="subscribed")
    one = await make_user(session, family=family, display_name="Travis")
    await make_user(session, family=family, display_name="Anna")
    await session.commit()

    response = await client.post("/v1/families/me/invites", json={}, headers=auth_headers(one))

    assert response.status_code == 409
    assert "two parents" in response.json()["error"]["message"]


async def test_a_viewer_invite_is_refused_while_phase_30_is_iceboxed(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, _ = await _subscribed_parent(session)

    response = await client.post(
        "/v1/families/me/invites", json={"role": "viewer"}, headers=auth_headers(user)
    )

    assert response.status_code == 422
    assert response.json()["error"]["field"] == "role"


# --- Preview, accept, revoke -------------------------------------------------------------


async def test_the_preview_is_unauthenticated_and_thin(
    client: AsyncClient, session: AsyncSession
) -> None:
    """You have to see what a link is before you can sign in to accept it."""
    user, child = await _subscribed_parent(session)
    token = (
        await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))
    ).json()["token"]

    response = await client.get(f"/v1/invites/{token}")  # no Authorization header

    assert response.status_code == 200
    body = response.json()
    assert body["invited_by"] == "Travis"
    assert body["children"] == [child.name]
    # First names and nothing else — no ids, no birthdates, no email addresses.
    assert set(body) == {"invited_by", "role", "expires_at", "children"}


async def test_an_unknown_token_is_a_flat_404(client: AsyncClient) -> None:
    assert (await client.get("/v1/invites/not-a-real-token")).status_code == 404


async def test_accepting_moves_the_user_and_grants_every_child(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, child = await _subscribed_parent(session)
    second = await make_child(session, name="Nora", parent=user)
    invitee = await make_user(session, display_name="Anna")
    await session.commit()
    token = (
        await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))
    ).json()["token"]

    response = await client.post(f"/v1/invites/{token}/accept", headers=auth_headers(invitee))

    assert response.status_code == 200
    assert set(response.json()["children"]) == {str(child.id), str(second.id)}

    await session.refresh(invitee)
    assert invitee.family_id == user.family_id
    granted = set(
        (
            await session.execute(
                sa.select(Guardian.child_id).where(Guardian.user_id == invitee.id)
            )
        ).scalars()
    )
    assert granted == {child.id, second.id}


async def test_accepting_twice_is_a_success_and_writes_nothing_the_second_time(
    client: AsyncClient, session: AsyncSession
) -> None:
    """A parent who taps, loses signal and taps again gets a household, not an error."""
    user, _ = await _subscribed_parent(session)
    invitee = await make_user(session, display_name="Anna")
    await session.commit()
    token = (
        await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))
    ).json()["token"]

    first = await client.post(f"/v1/invites/{token}/accept", headers=auth_headers(invitee))
    second = await client.post(f"/v1/invites/{token}/accept", headers=auth_headers(invitee))

    assert first.status_code == 200
    assert second.status_code == 200
    assert first.json() == second.json()
    rows = await session.scalar(
        sa.select(sa.func.count()).select_from(Guardian).where(Guardian.user_id == invitee.id)
    )
    assert rows == 1


async def test_an_expired_invite_cannot_be_accepted(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, _ = await _subscribed_parent(session)
    invitee = await make_user(session, display_name="Anna")
    await session.commit()
    token = (
        await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))
    ).json()["token"]
    await session.execute(
        sa.update(GuardianInvite).values(
            expires_at=dt.datetime.now(tz=dt.UTC) - dt.timedelta(minutes=1)
        )
    )
    await session.commit()

    assert (
        await client.post(f"/v1/invites/{token}/accept", headers=auth_headers(invitee))
    ).status_code == 404
    assert (await client.get(f"/v1/invites/{token}")).status_code == 404


async def test_a_revoked_invite_cannot_be_accepted(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, _ = await _subscribed_parent(session)
    invitee = await make_user(session, display_name="Anna")
    await session.commit()
    created = (
        await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))
    ).json()

    revoked = await client.delete(
        f"/v1/families/me/invites/{created['id']}", headers=auth_headers(user)
    )
    assert revoked.status_code == 204

    assert (
        await client.post(f"/v1/invites/{created['token']}/accept", headers=auth_headers(invitee))
    ).status_code == 404


async def test_a_stranger_cannot_revoke_someone_elses_invite(
    client: AsyncClient, session: AsyncSession
) -> None:
    user, _ = await _subscribed_parent(session)
    stranger = await make_user(session, display_name="Nobody")
    await session.commit()
    created = (
        await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))
    ).json()

    response = await client.delete(
        f"/v1/families/me/invites/{created['id']}", headers=auth_headers(stranger)
    )

    assert response.status_code == 404


# --- GET /families/me --------------------------------------------------------------------


async def test_the_family_read_lists_both_guardians_and_marks_you(
    client: AsyncClient, session: AsyncSession
) -> None:
    family = await make_family(session, tier="subscribed")
    one = await make_user(session, family=family, display_name="Travis")
    two = await make_user(session, family=family, display_name="Anna")
    child = await make_child(session, parent=one)
    await grant(session, two, child)
    await session.commit()

    body = (await client.get("/v1/families/me", headers=auth_headers(one))).json()

    assert body["tier"] == "subscribed"
    # By identity, not position. `family_members` orders by `created_at, id`, and two users
    # created inside one transaction share a `created_at` — `now()` is the transaction
    # timestamp — so the tiebreak is a random UUID. Deterministic, but not alphabetical.
    by_id = {g["user_id"]: g for g in body["guardians"]}
    assert set(by_id) == {str(one.id), str(two.id)}
    assert by_id[str(one.id)]["display_name"] == "Travis"
    assert by_id[str(one.id)]["is_you"] is True
    assert by_id[str(two.id)]["is_you"] is False


async def test_a_new_household_reads_as_free_with_one_guardian(
    client: AsyncClient, session: AsyncSession
) -> None:
    user = await make_user(session)
    await make_child(session, parent=user)
    await session.commit()

    body = (await client.get("/v1/families/me", headers=auth_headers(user))).json()

    assert body["tier"] == "free"
    assert len(body["guardians"]) == 1
    assert body["pending_invites"] == []


# --- The scheduler, per guardian ---------------------------------------------------------


async def _pool(session: AsyncSession) -> None:
    """Enough prompts that no slot has to fall back."""
    for kind, cadence in (
        ("question", "daily"),
        ("photo", "daily"),
        ("video", "daily"),
        ("activity", "weekly"),
    ):
        for _ in range(6):
            await make_prompt(session, kind=kind, cadence=cadence)


async def test_each_guardian_gets_their_own_daily_three(session: AsyncSession) -> None:
    family = await make_family(session, tier="subscribed")
    one = await make_user(session, family=family, display_name="Travis")
    two = await make_user(session, family=family, display_name="Anna")
    child = await make_child(session, parent=one)
    await grant(session, two, child)
    await _pool(session)
    await session.commit()

    await run_scheduler(session, as_of_date=TUESDAY, seed=7)
    await session.commit()

    rows = (
        await session.execute(
            sa.select(Assignment.slot, Assignment.user_id).where(
                Assignment.child_id == child.id, Assignment.assigned_on == TUESDAY
            )
        )
    ).all()
    assert len(rows) == 6  # three daily slots, two parents
    for parent in (one, two):
        assert {slot for slot, user_id in rows if user_id == parent.id} == {
            "question",
            "mission",
            "mission_b",
        }


async def test_a_shared_slot_is_created_once_for_two_guardians(
    session: AsyncSession,
) -> None:
    """The measurement mission must not fire twice a month because two people were served it."""
    family = await make_family(session, tier="subscribed")
    one = await make_user(session, family=family)
    two = await make_user(session, family=family, display_name="Anna")
    child = await make_child(session, parent=one)
    await grant(session, two, child)
    await _pool(session)
    await session.commit()

    await run_scheduler(session, as_of_date=SATURDAY, seed=7)
    await session.commit()

    weekly = (
        await session.execute(
            sa.select(Assignment.user_id).where(
                Assignment.child_id == child.id,
                Assignment.assigned_on == SATURDAY,
                Assignment.slot == "weekly",
            )
        )
    ).all()
    assert len(weekly) == 1
    assert weekly[0][0] is None


async def test_a_rerun_with_two_guardians_creates_nothing(session: AsyncSession) -> None:
    """Idempotency, which is the property the index swap could have broken silently."""
    family = await make_family(session, tier="subscribed")
    one = await make_user(session, family=family)
    two = await make_user(session, family=family, display_name="Anna")
    child = await make_child(session, parent=one)
    await grant(session, two, child)
    await _pool(session)
    await session.commit()

    first = await run_scheduler(session, as_of_date=SATURDAY, seed=7)
    await session.commit()
    second = await run_scheduler(session, as_of_date=SATURDAY, seed=7)
    await session.commit()

    assert first.created > 0
    assert second.created == 0
    total = await session.scalar(
        sa.select(sa.func.count())
        .select_from(Assignment)
        .where(Assignment.child_id == child.id, Assignment.assigned_on == SATURDAY)
    )
    assert total == first.created


async def test_the_cooldown_is_scoped_per_parent(session: AsyncSession) -> None:
    """Decision 1: two people answering the same question differently is the feature.

    One prompt in the pool, already served to one parent well inside the cooldown. The other
    parent must still be served it — a per-child cooldown would have left their slot empty.
    """
    family = await make_family(session, tier="subscribed")
    one = await make_user(session, family=family)
    two = await make_user(session, family=family, display_name="Anna")
    child = await make_child(session, parent=one)
    await grant(session, two, child)
    only = await make_prompt(session, kind="question", cadence="daily")
    session.add(
        Assignment(
            child_id=child.id,
            user_id=one.id,
            prompt_id=only.id,
            slot="question",
            assigned_on=TUESDAY - dt.timedelta(days=1),
            expires_on=TUESDAY + dt.timedelta(days=13),
        )
    )
    await session.commit()

    await run_scheduler(session, as_of_date=TUESDAY, child_id=child.id, seed=7)
    await session.commit()

    served = await session.scalar(
        sa.select(Assignment.prompt_id).where(
            Assignment.child_id == child.id,
            Assignment.assigned_on == TUESDAY,
            Assignment.slot == "question",
            Assignment.user_id == two.id,
        )
    )
    assert served == only.id


async def test_a_child_with_no_active_parent_gets_no_daily_rows(
    session: AsyncSession,
) -> None:
    """Honest rather than orphaned: there is nobody to serve a daily prompt to.

    The shared slots still fire, because they belong to the child.
    """
    user = await make_user(session)
    child = await make_child(session, parent=user)
    await session.execute(
        sa.update(Guardian)
        .where(Guardian.user_id == user.id)
        .values(revoked_at=dt.datetime.now(tz=dt.UTC))
    )
    await _pool(session)
    await session.commit()

    await run_scheduler(session, as_of_date=SATURDAY, child_id=child.id, seed=7)
    await session.commit()

    slots = set(
        (
            await session.execute(
                sa.select(Assignment.slot).where(
                    Assignment.child_id == child.id, Assignment.assigned_on == SATURDAY
                )
            )
        ).scalars()
    )
    assert slots == {"weekly"}


async def test_the_invitee_can_read_the_childs_data_through_the_existing_check(
    client: AsyncClient, session: AsyncSession
) -> None:
    """P7: accepting grants access by writing the rows `require_child_access` already reads.

    No new authorization path, which is why there is nothing new to keep in sync.
    """
    user, child = await _subscribed_parent(session)
    invitee = await make_user(session, display_name="Anna")
    await session.commit()
    token = (
        await client.post("/v1/families/me/invites", json={}, headers=auth_headers(user))
    ).json()["token"]

    path = f"/v1/children/{child.id}/stats"
    before = await client.get(path, headers=auth_headers(invitee))
    await client.post(f"/v1/invites/{token}/accept", headers=auth_headers(invitee))
    after = await client.get(path, headers=auth_headers(invitee))

    assert before.status_code == 403
    assert after.status_code == 200


# --- What "one household, one set of children" actually has to mean ----------------------


async def test_a_child_added_after_the_second_parent_joins_is_visible_to_both(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The promise the phase is sold on, and the way it would have broken quietly.

    `POST /children` used to grant only its caller. A child added after the second parent
    joined would have been invisible to them — and invisibly so, because a child nobody told
    you about looks exactly like a child that does not exist.
    """
    family = await make_family(session, tier="subscribed")
    one = await make_user(session, family=family, display_name="Travis")
    two = await make_user(session, family=family, display_name="Anna")
    await session.commit()

    created = await client.post(
        "/v1/children",
        json={
            "name": "Nora",
            "birthdate": "2026-01-02",
            "family_timezone": "America/Detroit",
        },
        headers=auth_headers(one),
    )
    assert created.status_code == 201
    child_id = created.json()["id"]

    seen = await client.get("/v1/children", headers=auth_headers(two))
    assert [c["id"] for c in seen.json()] == [child_id]


async def test_accepting_does_not_absorb_the_invitees_own_child(
    client: AsyncClient, session: AsyncSession
) -> None:
    """An invitee who already had an archive keeps it to themselves.

    Whether two existing archives should merge is a real product question nobody has
    answered. Until somebody does, accepting moves you *into* a household and grants you its
    children; it does not hand yours over.
    """
    inviter, theirs = await _subscribed_parent(session)
    invitee = await make_user(session, display_name="Anna")
    mine = await make_child(session, name="Bob", parent=invitee)
    await session.commit()
    token = (
        await client.post("/v1/families/me/invites", json={}, headers=auth_headers(inviter))
    ).json()["token"]

    accepted = await client.post(f"/v1/invites/{token}/accept", headers=auth_headers(invitee))

    # The invitee gains the inviter's child and keeps their own.
    assert accepted.json()["children"] == [str(theirs.id)]
    invitee_sees = {
        c["id"] for c in (await client.get("/v1/children", headers=auth_headers(invitee))).json()
    }
    assert invitee_sees == {str(theirs.id), str(mine.id)}
    # The inviter gains nothing they were not offered.
    inviter_sees = {
        c["id"] for c in (await client.get("/v1/children", headers=auth_headers(inviter))).json()
    }
    assert inviter_sees == {str(theirs.id)}


async def test_the_preview_lists_only_the_inviters_children(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The unauthenticated route must not disclose a name it was never offered."""
    inviter, theirs = await _subscribed_parent(session)
    outsider = await make_user(session, display_name="Someone")
    await make_child(session, name="NotYours", parent=outsider)
    await session.commit()
    token = (
        await client.post("/v1/families/me/invites", json={}, headers=auth_headers(inviter))
    ).json()["token"]

    body = (await client.get(f"/v1/invites/{token}")).json()

    assert body["children"] == [theirs.name]


# --- The read paths. Each parent sees their own board and only their own. ----------------


async def _two_parent_household(session: AsyncSession):
    family = await make_family(session, tier="subscribed")
    one = await make_user(session, family=family, display_name="Travis")
    two = await make_user(session, family=family, display_name="Anna")
    child = await make_child(session, parent=one)
    await grant(session, two, child)
    await _pool(session)
    await session.commit()
    return one, two, child


async def test_today_shows_a_parent_their_own_three_and_not_the_others(
    client: AsyncClient, session: AsyncSession
) -> None:
    """**The defect that would have made this whole phase pointless.**

    Per-guardian assignment is only worth anything if the read path is scoped too. Unscoped,
    a two-parent household's board shows six daily items — three of them the other parent's,
    which this parent can see and complete.
    """
    one, two, child = await _two_parent_household(session)
    # **No `?date=`, and that is the fix rather than a simplification.** This read used to pass
    # `dt.date.today()` — the *test machine's* date — while `today.py` computes `local_today` in
    # the child's `family_timezone` and only calls `ensure_day_filled` when the two agree. On a
    # UTC runner between 00:00 and ~04:00 UTC it is already tomorrow in America/Detroit's terms,
    # so the dates disagreed, the day was never filled, and the board came back empty: *"Travis
    # saw 0 daily items"*. It passed on any machine in US time and failed in CI for four hours a
    # day. Omitting the parameter asks for the same thing the app asks for.
    for viewer in (one, two):
        body = (
            await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(viewer))
        ).json()
        daily = [i for i in body["today"] if i["slot"] in ("question", "mission", "mission_b")]
        assert len(daily) == 3, f"{viewer.display_name} saw {len(daily)} daily items"

    # And they are genuinely different rows, not the same three twice.
    ids = []
    for viewer in (one, two):
        body = (
            await client.get(f"/v1/children/{child.id}/today", headers=auth_headers(viewer))
        ).json()
        ids.append({i["id"] for i in body["today"] if i["slot"] == "question"})
    assert ids[0] and ids[1] and ids[0].isdisjoint(ids[1])


async def test_a_shared_slot_reaches_both_parents(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The other half of the scoping: `weekly` belongs to the child, so both see it."""
    one, two, child = await _two_parent_household(session)
    saturday = dt.date(2026, 8, 22)  # future-date: explicit, pure
    await run_scheduler(session, as_of_date=saturday, child_id=child.id, seed=7)
    await session.commit()

    for viewer in (one, two):
        body = (
            await client.get(
                f"/v1/children/{child.id}/today?date={saturday.isoformat()}",
                headers=auth_headers(viewer),
            )
        ).json()
        slots = {i["slot"] for i in body["today"]}
        assert "weekly" in slots, f"{viewer.display_name} cannot see the shared weekly"


async def test_sync_does_not_hand_a_parent_the_other_parents_assignments(
    client: AsyncClient, session: AsyncSession
) -> None:
    """The same leak, except it persists in the device's local cache."""
    one, two, child = await _two_parent_household(session)
    await run_scheduler(session, as_of_date=TUESDAY, child_id=child.id, seed=7)
    await session.commit()

    pulled = {}
    for viewer in (one, two):
        body = (
            await client.get(f"/v1/sync?child_id={child.id}", headers=auth_headers(viewer))
        ).json()
        pulled[viewer.id] = {
            a["id"]
            for a in body["assignments"]
            if a["slot"] in ("question", "mission", "mission_b")
        }

    assert len(pulled[one.id]) == 3
    assert len(pulled[two.id]) == 3
    assert pulled[one.id].isdisjoint(pulled[two.id])


# --- The cap under concurrency ------------------------------------------------------------


async def test_two_simultaneous_accepts_cannot_both_join_one_household(
    client: AsyncClient, session: AsyncSession, engine
) -> None:
    """**Genuinely concurrent, not two sequential calls.**

    The cap is a read-then-write and nothing in the schema enforces it — "at most two rows in
    `users` for one `family_id`" is not something a unique index can say. Without the row lock
    in `accept_invite`, both transactions read one member, both pass the check, and the
    household ends up with three adults on a one-household subscription.

    Two invites, two invitees, two sessions, both accepts started before either commits.
    """
    inviter, _child = await _subscribed_parent(session)
    a = await make_user(session, display_name="Anna")
    b = await make_user(session, display_name="Ben")
    await session.commit()

    tokens = [
        (
            await client.post("/v1/families/me/invites", json={}, headers=auth_headers(inviter))
        ).json()["token"]
        for _ in range(2)
    ]

    factory = async_sessionmaker(bind=engine, expire_on_commit=False, autoflush=False)

    async def attempt(raw_token: str, joiner):
        async with factory() as s:
            invite = await s.scalar(
                sa.select(GuardianInvite).where(GuardianInvite.token_hash == hash_token(raw_token))
            )
            joining = await s.get(User, joiner.id)
            try:
                await accept_invite(s, invite, joining)
                await s.commit()
                return "accepted"
            except RascalError as exc:
                await s.rollback()
                return exc.code

    outcomes = await asyncio.gather(
        attempt(tokens[0], a), attempt(tokens[1], b), return_exceptions=True
    )

    assert "accepted" in outcomes, outcomes
    assert ErrorCode.CONFLICT in outcomes, f"both accepts succeeded: {outcomes}"

    members = await session.scalar(
        sa.select(sa.func.count()).select_from(User).where(User.family_id == inviter.family_id)
    )
    assert members == 2
