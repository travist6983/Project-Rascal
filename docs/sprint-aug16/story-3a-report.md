# Story 3a — guardians, the server half. Report.

## ALREADY LANDED. Gate 3, exit 0. No phase number consumed.

Story 3a's gate 3: *"If `families`, `entitlements` and `guardian_invites` all exist in alembic
history and the invite routes are present, report `ALREADY LANDED` and exit 0."*

All of it exists. **Phase 36 shipped this on Aug 17, 2026** — the story was written against a
tree where it had not, which is the same staleness that made stories 1, 2, 4 and 5 wrong.

## The evidence, checked rather than assumed

| Gate-3 artifact | Where it is |
|---|---|
| `families`, `entitlements`, `guardian_invites` | `alembic/versions/0014_families_and_invites.py` |
| Invite routes | `routers/families.py` — `GET /families/me`, `POST /families/me/invites`, `DELETE /families/me/invites/{id}`, `GET /invites/{token}`, `POST /invites/{token}/accept` |
| Router mounted | `main.py:89`, `app.include_router(families.invites_router, ...)` |
| Free-tier gate | `services/guardians.py:165`, `if not entitlement.is_subscribed` |
| Per-guardian daily slots | `0014`: `uq_assignments_daily` (child, user, date, slot) and `uq_assignments_shared` (child, date, slot) |

That last row is the one the story called *"the only migration that can damage an existing
archive"*, and it is the one that proves this is genuinely the same work: the old
`uq_assignments_child_id_assigned_on_slot` is dropped and replaced by exactly the two partial
indexes story 3a specifies — daily slots keyed per guardian, shared slots keyed per child.

## Its four settled decisions are all implemented

1. **Prompt cooldown per-parent** — served through the per-guardian daily index.
2. **Daily slots per-parent, larger slots shared** — the two partial indexes, and
   `services/scheduler.py` passes `index_where` matching the daily predicate so `ON CONFLICT`
   infers the right one. That detail is not incidental: without it the upsert cannot name which
   partial index it means, and the scheduler fails at runtime rather than at import.
3. **A real entitlement row** — `entitlements`, not deferred.
4. **The free tier does not get a second guardian** — the gate above.

## Gate 4, and why the window it guarded is closed

Gate 4 required querying **production** for any child with more than one active guardian, and
halting if any row returned — because the backfill attributes every existing daily assignment to
the sole guardian of its child, which is correct with one and unrecoverably wrong with two.

That check was run against production during phase 36 and returned **0 rows**, which is what made
the migration safe to apply. It has since been applied and deployed. **The check is not
re-runnable now and must not be re-run as though it were**: the migration it guarded has already
happened, and the same query today answers a different question.

`0014` also carries a `DO $$ ... RAISE EXCEPTION` guard refusing to migrate if any child has more
than one active parent, so the safety is in the migration itself rather than only in a gate
somebody remembered to run.

## For story 7

**Un-iceboxing 36 restored D4's consumer.** "One price for the whole household" now has the thing
it is sold on, which is the consequence story 3a asked to have recorded. Open question 11 is
closed by the same work.
