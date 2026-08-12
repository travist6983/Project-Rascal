# Phase 20 (pronouns) — preflight

Run 2026-08-11 against `main` (`b29b5e8`), on branch `ios/phase-20-pronouns`. All three spec'd
checks pass on substance. Two of the three spec'd *commands* were wrong about this repo and were
corrected; the corrections are recorded below rather than worked around silently.

**Gate result: PASS.**

> **On the number.** `docs/decisions.md:188` says this work "has no phase number", because the
> number it was drafted against shipped as the nine TestFlight defects (PR #47), and
> `docs/roadmap-status.md:172` says existing collisions are deliberately never renumbered. The
> collision was raised before the branch was opened and `phase-20` was confirmed as the name to
> use anyway. **Phase 20 now means two things**, and the ledger stays the disambiguator exactly
> as `roadmap-status.md` already anticipates for the other three collisions.

---

## 0. Repo state — the tree is mid-merge, and the branch cannot be cut from here

Not one of the spec's checks, but it gates "open a branch".

```
$ git status --short --branch
## tmp/conflict-probe...origin/api/export-html-viewer
UU docs/decisions-log.md
UU docs/roadmap-status.md
   (+33 staged files from the API-lane export-html-viewer work)
```

`.git/MERGE_HEAD` is `b29b5e8` — `main`, via PR #50. Someone was probing whether `main` merges
cleanly into `api/export-html-viewer`; it does not, and two doc files are unresolved. **That
state is unrelated to pronouns and is left untouched.**

The base is nonetheless clean, and this is verified rather than assumed:

```
$ git diff b29b5e8 -- ios/ --stat
(empty)
```

The working tree's `ios/` is byte-identical to `main`, so the baseline in check 3 is a valid
baseline for a branch cut from `main`, and `main` is the correct base.

---

## 1. Allowed values — read, not assumed

`api/src/rascal/constants.py:74-75`

```python
Pronouns = Literal["he/him", "she/her", "they/them"]
PRONOUNS: Final = ("he/him", "she/her", "they/them")
```

**Exactly three values. Slash separator, lowercase, no spaces. There is no fourth value.**

- CHECK constraint: `one_of("pronouns", PRONOUNS, name="pronouns")` — `models/child.py:17`
- Column: `pronouns: Mapped[Pronouns | None]`, nullable — `models/child.py:25`
- Present on `ChildCreate` (`schemas/child.py:20`), `ChildUpdate` (`:37`), `ChildOut` (`:53`)

**The picker offers all three and narrows nothing.** The constraint permits three values, the
picker sends those three strings verbatim, and skipping sends `null` — which the column allows
and which the schema comment explicitly distinguishes from an answer: *"absent is not
'they/them' — it is unanswered."*

## 2. The write path persists

**The spec's verification command names a route that does not exist.** There is no
`GET /children/{id}`. Registered routes:

```
/v1/children            get, post
/v1/children/{child_id} patch
```

`curl localhost:8000/v1/children/$CHILD_ID` returns `{"error":{"code":"internal_error",
"message":"Method Not Allowed"}}`. Piping that through `jq '{pronouns}'` yields
`{"pronouns":null}` — an error object rendered as a plausible-looking null. The first run of
this check read that as a failed write. It was not; the read path is the list endpoint.

Re-run against `GET /v1/children`, reading back the child by id each time:

| Step | PATCH response | fresh GET |
|---|---|---|
| `{"pronouns":"she/her"}` | `she/her` | `she/her` |
| `{"pronouns":"they/them"}` | `they/them` | `they/them` |
| `{"pronouns":"he/him"}` | `he/him` | `he/him` |
| `{"pronouns":null}` | `null` | `null` |
| then `{"name":"…"}` alone | — | `null` (not resurrected) |

- **`POST /children` accepts `pronouns` on create** — returns `"pronouns":"she/her"` on the
  created row, so onboarding needs no second round trip.
- **Explicit `null` clears rather than being ignored**, and stays cleared through a subsequent
  unrelated PATCH. The phase-19-shaped bug is **not** present on this route.
- Invalid values are rejected cleanly:
  `422 {"code":"validation_failed","field":"pronouns","message":"Input should be 'he/him',
  'she/her' or 'they/them'"}`

Left behind: one fixture child (`Preflight Kid`) in the **local** dev database. There is no
child-delete route, so it stays; it touches nothing else.

## 3. Baseline

**The spec's simulator does not exist on this machine.** `iPhone 15 Pro Max` is not installed;
the available iPhones are 16e, 17, 17 Pro, 17 Pro Max, 17e and Air, on OS 26.3.1 / 26.4.1. The
spec's command fails at destination resolution and builds nothing.

Re-run on the nearest available device, from a deleted `DerivedData`:

```
rm -rf ~/Library/Developer/Xcode/DerivedData
xcodebuild test -scheme Rascal \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.4.1' \
  CODE_SIGNING_ALLOWED=NO
```

```
✔ Test run with 714 tests in 87 suites passed after 14.446 seconds.
** TEST SUCCEEDED **
```

| | Baseline |
|---|---|
| Tests passing | **714** |
| Suites | **87** |
| Failures | **0** |
| Source warnings | **21** |

The suite is **Swift Testing**, not XCTest. The `Executed 0 tests, with 0 failures` line in the
output is the empty XCTest harness and is not the result; reading it as one would report a green
run over zero tests.

The 21 warnings match the spec's stated inherited count exactly, which is independent
corroboration that the substituted simulator changed nothing material. They are:

| Count | Warning | File |
|---|---|---|
| 14 | `lock`/`unlock` unavailable from async contexts | `RascalTests/PushPermissionTests.swift` |
| 4 | same | `RascalTests/ExtractionTests.swift` |
| 3 | `nilIfEmpty` main actor-isolated from nonisolated context | `Extraction/ExtractedDetails.swift` |

A 22nd line, `Metadata extraction skipped. No AppIntents.framework dependency found.`, is a
toolchain note with no source location and is excluded from the count.

**None of these three files is one this phase touches**, so "zero warnings in any file this
phase touches" and "the 21 stay 21" are both achievable without adopting any of them.

---

## Findings that change the work

### The design half is already settled and merged — B1 is written

`docs/decisions.md` open item 10 is **closed**, Aug 11 2026, via PR #50:

> ✅ **Answered Aug 11, 2026 — collected in onboarding and Settings, rendered from a
> fourteen-token contract, and the 113 seeded prompts are untouched.**

`docs/api-contract.md:696` already carries *Prompt pronoun tokens — a wire-format contract*:
the same fourteen tokens, the same four columns, the same they/them-are-the-keys argument, the
same three invariants. It is identical to the spec's B1 table — checked cell by cell, not
skimmed.

Per `CLAUDE.md`, `docs/decisions.md` is settled and not to be relitigated. **So B1 is not work;
it is the contract the implementation must match.** What remains is the client implementation
(A1, A2, B2) and the authoring rule (B3).

### The phase number is taken, twice over

`docs/decisions.md:188`:

> **The client work is unstarted and has no phase number** — the number this was drafted
> against, phase 20, has since shipped as the nine TestFlight defects (PR #47).

`docs/roadmap-status.md:172` records that existing phase-number collisions are **deliberately
not renumbered**, because renaming a merged phase would produce a ledger disagreeing with every
PR title in the repo. Opening `ios/phase-20-pronouns` would make phase 20 mean a *third* thing.
This is the one open decision.

### `ChildResponse` does not decode `pronouns`

`Networking/RascalAPI.swift:68-75` carries `id`, `name`, `birthdate`, `familyTimezone`,
`ageMonths`, `role`. The server sends `pronouns` on every one of these payloads and **the
client drops it on the floor**. Adding the field is a prerequisite for Settings showing a value
at all — without it there is nothing to render and nothing to seed the picker's current state.

### Prompt text *is* cached — in two SwiftData models

The spec asks that this be established rather than assumed. It is cached in two places:

- **`Assignment.body`** — SwiftData, the whole Today board
- **`Entry.promptBody`** — SwiftData, written at `Composer/ComposerView.swift:693`
  (`entry.promptBody = assignment.body`) and at `Models/Entry.swift:167`

**If both keep storing the raw tokenised text and rendering happens at display time, a pronoun
change needs no cache invalidation at all** — the next render is simply correct, with no
relaunch and no purge. That is the cheapest way to satisfy "must take effect on already-rendered
prompts", and it is also the only one that keeps an eighteen-year archive re-renderable.

**The widget snapshot is the one genuine exception.** `Widget/WidgetSnapshotBuilder.swift:65`
writes `body: found.assignment.body` into a snapshot the extension reads without networking, so
that copy is necessarily *rendered* text and must be rebuilt when pronouns change —
`WidgetSnapshotSync` / `WidgetSnapshotPublisher` are the trigger points.

### A trap the spec does not name: `entry.body` is not a prompt

`entry.body` is **the parent's own words** (`Models/Entry.swift:182`,
`Composer/ComposerView.swift:787`, `Timeline/EntryDetailScreen.swift:275`). It sits one
character away from `entry.promptBody` in the same model and reads identically at a glance.

**The renderer must never touch it.** A parent who typed `{they}` literally — or wrote about a
game with braces in its name — would have their sentence silently rewritten in a permanent
archive, which is precisely the failure mode invariant 3 exists to prevent, arriving through the
other door. Only `assignment.body` and `entry.promptBody` render.

### Where a prompt body reaches a human

Every site, from `grep`, with the intended disposition:

| Site | Disposition |
|---|---|
| `Today/PromptCard.swift:29` — `Text(assignment.body)` | render |
| `Today/PromptCard.swift:161` — accessibility label | render |
| `Today/DoneCard.swift:126` — accessibility label | render |
| `Today/WaitingCard.swift:85` — accessibility label | render |
| `Today/TodayScreen.swift:36` — skip-toast `Skipped "…"` | render |
| `Composer/ComposerView.swift:634` — quoted prompt | render |
| `Timeline/EntryCardModel.swift:189` — `prompt: entry.promptBody` | render |
| `Timeline/EntryDetailScreen.swift:159-161` — quoted prompt | render |
| `Widget/WidgetSnapshotBuilder.swift:65` | render **before** the snapshot is written |
| `Composer/ComposerView.swift:693` — `entry.promptBody = assignment.body` | **store raw** |
| `Models/Entry.swift:167`, `Models/Assignment.swift:107/149` | **store raw** |
| `Today/TodayPreviewData.swift:107/138` | fixtures — render, so previews match production |

The accessibility labels matter as much as the visible text: a card that reads correctly and
*sounds* wrong to VoiceOver is the same defect with a smaller audience.

### Smaller corrections

- **`scripts/generate_prompts.py` does not exist at that path.** It is
  `api/scripts/generate_prompts.py`, tested by `api/tests/test_generate_prompts.py`. The B3
  edit target — the style-reference section of `docs/mission-library.md`, around line 247 — is
  real, and currently contains **no** token or `{name}` rule. B3 is genuinely unstarted.
- **B3 is an authoring rule, not an enforced one.** The generator's four rejection rules are
  implemented in code and tested; a `{name}`-at-most-once rule added to the markdown constrains
  the model's style reference but is not checked anywhere. Worth knowing before treating it as
  a guarantee. Adding a filter would be a Lane A change and is not in this phase.
- **The onboarding flow has a step the spec omits.** Actual steps in
  `Onboarding/ChildSetupFlow.swift:46-50` are name → birthdate → timezone → avatar →
  **notifications**. The spec describes "…→ avatar → Today". Inserting pronouns after birthdate
  is unaffected, but the flow is five steps, not four.
- **The candidate count is ~80, not 79** — four files of 20 each. Out of scope either way;
  noted only so the number is not quoted onward as verified.
- **The design bundle's README points at a filename that is not in the bundle**
  (`mobile-app-design-pending/project/RASCAL Onboarding.dc.html`). The real file is
  `docs/mobile-app-design-onboarding/project/RASCAL Onboarding.dc.html`; the export names
  whichever file was open at handoff.

---

## Found after the gate, during implementation

Recorded here rather than in the PR alone, because both are facts about the contract rather than
about this diff.

### The contract's prose and its table disagree about the token count

`docs/api-contract.md` says **"Fourteen tokens, one dictionary, no logic"** and then lists
**thirteen** rows. `docs/decisions.md` repeats the same sentence over the same table. Counted:

nine lowercase (`{they}` `{them}` `{their}` `{theirs}` `{themself}` `{they_are}` `{they_were}`
`{they_have}` `{they_do}`) + three capitalised (`{They}` `{Them}` `{Their}`) + `{name}` = **13**.

**Thirteen is implemented**, because the table is the substance and "fourteen" is a description of
it. A client inventing a fourteenth token to satisfy a sentence would be adding to a wire-format
contract that a browser client, an export and a printed book also have to honour. The two obvious
candidates — `{Theirs}` and `{Themself}` — are precisely the capitalised forms the table appears to
omit deliberately, since neither plausibly opens a sentence.

`PronounRenderingTests.tokenSetMatchesTheContract` pins the set and records the discrepancy.
**Reconciling the prose is an API-lane edit** (`docs/api-contract.md` belongs to that lane per
`CLAUDE.md`) and was not made here.

### `updateChild` could not have cleared a pronoun without a hand-written encoder

`SettingsAPI.updateMe` already documents that Swift's synthesized encoder uses `encodeIfPresent`
for optionals — a nil is *omitted*, not sent as `null` — and notes that none of its columns is
nullable so there is no unset to express. `children.pronouns` is the case that note excludes: it is
nullable, the server reads `model_fields_set`, and only an explicit `null` clears it.

The synthesized encoder cannot express that difference, so `ChildUpdateRequest` is now written out
by hand for one property. Without it, Clear would have silently no-opped — the exact shape of the
phase-19 seal bug that preflight check 2 was told to look for, arriving on the write side instead
of the read side.
