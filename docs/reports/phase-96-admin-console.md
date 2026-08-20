# Phase 96 — the admin console

**Aug 19, 2026. API lane. Branch `api/phase-96-admin-console`. Local only — nothing deployed.**

An admin console at `/admin`: what the business looks like, an editor for the mission library, what
the vendors are charging, and whether the scheduled jobs actually ran. Built in one sitting against
the owner's ask — *"edit the prompts, pull billing where we can, see total customers, and anything
else useful, just don't deploy it."*

---

## What it is

Four screens behind `users.is_admin`, served as three static files from the API itself. No build
step, no npm, no dependency added to `pyproject.toml`, no third-party script on the page — which is
what lets its CSP be `default-src 'self'` with no exceptions.

**Today.** Moments kept, a gap-filled column chart of entries per day, six stat tiles with
sparklines (households and tiers, kids, signed in this week, prompt completion rate, bytes stored,
library size), what the archive is made of by entry type, which themes people finish, and the
newest accounts.

**Library.** All 233 bodies with filters and search. Every row carries how many times the prompt has
been served, how many of those became a finished entry, and whether an override is holding it
against the seed file. Clicking one opens an editor with a **live three-column pronoun preview** and
token validation.

**Costs.** Five vendor cards, fetched concurrently and cached.

**Ops.** A slot × day grid of what the scheduler produced, the switches that gate each subsystem
with a sentence saying what each one gates, the migration head, the broadcast ledger, notification
counts and the deletion queue.

---

## The one hard problem, and it is not the UI

`seed_prompts` runs as `fly.toml`'s `release_command`. It reconciles `prompts` against
`api/seeds/prompts.yaml` **totally** — the upsert writes the file's `active` and the retirement
sweep deactivates every `source = 'seeded'` row the file no longer lists.

So a naive admin console loses every edit within minutes of the next deploy, and loses body edits in
the worst possible way: `content_hash` is `sha256(kind, cadence, body)`, so an edited row is a row
the file does not contain — retired — **and the original body is re-inserted**. The archive ends up
serving exactly the copy the edit replaced, with no error anywhere.

The fix is one new table, `prompt_library_overrides`, keyed on `content_hash` and read by
`_apply_overrides` as the **last** statement in the seed transaction. Editing a seeded body is
modelled as what it is — a fork:

1. insert a new `source: "user"` prompt with the new words (the one source a re-seed never touches),
2. write an override retiring the original's hash,
3. deactivate the original now, so the change is live before the next deploy rather than after one.

Steps 1 and 2 are both required. Insert alone leaves both copies serving. Override alone leaves a
retired prompt and nothing in its place. The original row is never deleted — assignments and entries
point at it and must keep resolving for eighteen years.

**Six of the sixteen library tests run `seed_prompts` after the edit.** That is the only way to see
this class of bug: the response body is correct in every case, and the damage happens on a deploy an
hour later. `tests/test_library_overrides.py::test_the_fork_survives_a_re_seed` is the one that
matters.

Rejected, and why: writing back to `docs/mission-library.md` (`docs/` is not in the image — the same
wall phase 69 hit with email copy, and a container filesystem is ephemeral anyway); writing
`prompts.yaml` (CLAUDE.md forbids hand-editing it, and same ephemerality); dropping `active` from
`MUTABLE_FIELDS` (that silently removes the file's ability to retire a prompt, which is the exact
mechanism phase 24 used on 113 bodies at once).

---

## Billing: what is knowable and what is not

| Vendor | Publishes spend? | Credential | Working tonight |
|---|---|---|---|
| Anthropic | **yes** — `/v1/organizations/cost_report` | `ANTHROPIC_ADMIN_KEY` | no — needs the key |
| Fly | no | `FLY_API_TOKEN` | no — needs the token |
| Neon | no | `NEON_API_KEY` + `NEON_PROJECT_ID` | no — needs the key |
| Tigris | no | the S3 keys media already uses | **yes** |
| Resend | no | `MAIL_API_KEY`, already set | **yes** |

Two cards are live with no new credentials: Tigris reports **90 MB across 56 objects, all under
`children/`**, and Resend reports the sending domain `mail.getvellumapp.com` as **verified** and
`RESEND_AUDIENCE_ID` as unset — which is also why `POST /v1/subscribe` currently refuses.

**Only Anthropic gets a dollar figure, and the other four do not get an invented one.** A number
estimated from published rates is a number nobody can reconcile against an invoice, and it is
exactly the kind of figure a dashboard is trusted about and never re-checked. The single opt-in
exception is `STORAGE_PRICE_CENTS_PER_GB_MONTH`; it defaults unset and the card names the setting
in the sentence beside the estimate.

Two traps handled explicitly, both of which would have been silently wrong:

- The cost report needs an **admin** key (`sk-ant-admin…`). An ordinary `sk-ant-api…` key 401s, and
  the message reads like a permissions problem rather than a wrong-kind-of-key problem — so the
  card says which it is.
- Anthropic's `amount` is **cents as a decimal string**: `"123.45"` is $1.23, not $123.45. Read as
  dollars it overstates the bill a hundredfold. Summed in `Decimal`, rounded once.

An unconfigured provider is a first-class state, not an error: the card carries the environment
variable to set and where the key comes from. "Not connected" with no next step is a dead end.

---

## Counts, never content

No admin route can return an entry title or body, a caption, a transcript, a child's name, or an
object key. The owner is the only admin, so this is not about trust — it is that a browser console
able to page through a family's archive is a different product with a different threat model, and
the cheapest moment to decide it will never exist is before the first query is written.

`tests/test_admin.py` plants five distinctive strings in an archive and asserts none of them appears
in any admin response. A rule with no compiler behind it decays into a comment.

The route sweep asserts its own completeness against `app.openapi()`, so an admin route added later
and wired to `CurrentUser` instead of `AdminUser` fails the suite rather than shipping.

---

## What it found on the way

**The scheduler grid works, and it is already saying something.** Against the local database,
`mission_b` has served nothing for a fortnight while `mission` and `question` served every day. That
may be local churn rather than a defect — but it is the shape of PR #57's finding, and it is the
"read the rows, not the deploy" instrument `roadmap-status.md` has been asking for. **The same panel
pointed at production is the check that has never had a screen.**

**The phase number rule has a fourth blind spot.** The three commands `phase-queue.md` prescribes
returned 95. 95 was already taken — by the *content* of `docs/decisions-log.md`, committed under a
subject line that names no phase. A docs commit can spend a number without its message ever saying
so, and none of the three measurements looks inside a file. `grep -rhoiE 'phase[- ][0-9]+' docs/` is
now the fourth line of the rule.

**One rendering bug worth naming**, because it is a class rather than a typo: `.panel` set
`display: flex`, which silently beats the UA stylesheet's low-specificity `[hidden] { display:
none }`. Tabs highlighted correctly and left the previous panel on screen. Caught by looking at the
page, not by any test — the DOM assertions all passed, because `hidden` was set exactly as intended.

---

## Numbers

- **862 tests pass**, 1 skipped, via `make test`. 39 new (`test_admin.py` 23, `test_library_overrides.py` 16).
- `ruff check` and `ruff format --check` clean over `api/` and `.github/`, which is the wider scope CI uses.
- Migration `0017_prompt_library_overrides`, up and down, with the trigger and both expectation lists updated in `tests/test_migrations.py` and `.github/scripts/verify_schema.py`.
- Nine new endpoints. `/v1/admin/{snapshot,library,ops,costs}`, `/v1/prompts/preview`, `PATCH /v1/prompts/{id}`, `PUT /v1/prompts/{id}/active`, `DELETE /v1/prompts/{id}/override`, and `GET /admin`.
- Zero new dependencies.

---

## Open, and deliberately left

- **Nothing is deployed.** The owner asked for local only. Shipping it needs `fly deploy` and
  nothing else — the migration is reversible and the console is inert without an admin token.
- **Three cost cards need a credential each**, all read-only, all named on the card itself.
- **No pagination on the library beyond `limit`/`offset`.** 233 bodies fit in one request; a
  thousand would not.
- **`GET /admin/costs` walks the whole bucket** with a 20,000-object cap, and says so on the card
  when it hits it. Past that the count is a floor, not a total.
- **The console has no write path to anything but the library.** Entitlements, deletions and
  broadcasts are readable and not editable. Making a tier writable from a web page is a decision
  about D5, not a missing button.
