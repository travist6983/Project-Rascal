# The export audit — is *"Search the whole archive, and export all of it whenever you want."* true?

> **A note on this document's own citations, added when it was committed.**
>
> This report was written, adversarially verified, corrected and verified again — three passes —
> **while the phase 124/125/126 code it describes was still being edited in the same tree.** Every
> pass found stale line numbers in the pass before it, and the last recheck found several more,
> because the anchors kept moving underneath. Two consequences, stated rather than hidden:
>
> 1. **Line numbers in this document may be off by a few lines.** The file names, the symbol names
>    and the findings were each verified by reading; the integers were true when written. Chase a
>    symbol, not a line.
> 2. **One recheck finding was a false positive caused by this very race** — an agent read
>    `ios/Rascal/Config.xcconfig` during a break-test window in which the two legal keys had been
>    temporarily removed, and reported that the file defines neither. It defines both. The file is
>    87 lines and carries them at `TERMS_URL` / `PRIVACY_URL`;
>    `SubmissionComplianceTests.theLegalURLsResolveInThisBuild` asserts they resolve at runtime and
>    passes.
>
> **The findings are the deliverable; the line numbers are a convenience.** Nothing in the analysis
> below turns on an integer.



**The mechanism is settled; the reading is the owner's, and under this repository's own vocabulary the line is true.** What is verified fact: there is exactly one export route, it is scoped to one child, and no surface anywhere offers a household-wide export — a two-child household takes **two downloads, one per child, from whichever child is currently selected**, because the client can only ever ask for the selected one. What is *not* a fact is what *"the whole archive"* promises. It has two readings — **complete rather than partial**, or **everything this household has** — and the choice between them is a copy judgment, so it is flagged here rather than decided. **This repository uses the phrase in the first sense wherever it uses it as a term of art; eight such sites are cited in §8.2 and a full sweep turned up no counterexample**, and **under that reading the paywall line is true and nothing needs to change.**

Everything else the sentence promises is true and is verified line by line below. **Both halves are ungated**: the export is entitlement-free on both sides of the wire (§3.1), and so is `GET /entries?q=`, the search the first half of the sentence names (§3.2) — a half the first pass of this audit never examined. The export carries media as well as text; it carries the originating prompt beside every answer; it respects `occurred_at` against `created_at` rather than flattening them; it includes soft-deleted entries and sealed letters; and it is one tap from Settings with nothing in front of it. A second, smaller gap is **disclosed rather than hidden**: the child's photo is in no export, and `ChildPhotoCopy.footnote` tells the parent so in the app. One claim that is true today but **time-bound** is now flagged as such in §3.1 rather than stated flatly.

**This paragraph is a correction.** The first pass of this audit opened by asserting that the claim *"is false in one respect"* because a two-child household has no single download. That was an interpretation of ambiguous copy presented as a verified falsity. The mechanism it described was right; the verdict it drew from it was a reading it never named as one. Nine further factual errors from that pass are fixed below and are itemised in §11.

**And this paragraph is a correction of the correction.** The second pass added that the first had *"silently overturned `docs/reports/phase-124-preflight.md:35-39`, which quotes the same block and concludes 'No contradiction to report.'"* **That is withdrawn: it is not what the preflight says.** `phase-124-preflight.md:36-38` quotes the **pre-phase-125** strings — *"A question every day, forever / Everything you've already written or captured / Search, and a full export of the whole archive"* — not the sentence under audit here, and `:39`'s *"No contradiction to report"* answers the question posed at `:35`, which is whether the block contradicts **D2-as-reversed and D3-as-narrowed**. Different copy, different question. Nothing was overturned. The same withdrawn claim was carried into `docs/decisions-log.md:816-822` by the second pass and is wrong there too; correcting that file is an edit, not an audit finding, and is left to whoever owns that entry.

**Aug 26, 2026.** Phase 126, Part 1 — corrected pass, revised again after an independent recheck. Read-only audit of the working tree on branch `ios/phase-124-submission-compliance`, HEAD `d7ece87` (*"Merge pull request #173 from travist6983/api/phase-127-siwa-revocation"*), **with the uncommitted phase 124/125/126 work in the tree**: `git status --porcelain` prints **sixteen** lines — fourteen modified files and two untracked — enumerated in §12. Nothing in the tree was changed by this pass, no build was run, and no test was executed — see §12.

---

## 0. The sentence under audit, and the fact that it changed

The audited sentence is `MembershipCopy.stayFree[2]`, at `ios/Rascal/Rascal/Subscription/MembershipCopy.swift:131`, under `freeLabel` (`:123`).

| | Value | VERIFIED-BY-READING |
|---|---|---|
| **On the branch now** | *"Search the whole archive, and export all of it whenever you want."* | `MembershipCopy.swift:131` (working tree) |
| **At `d7ece87` (previous)** | *"Search, and a full export of the whole archive"* | `git show HEAD:…/MembershipCopy.swift`, line 131 |
| **`freeLabel` now** | *"Yours either way"* | `MembershipCopy.swift:123` |
| **`freeLabel` at `d7ece87`** | *"What stays free, always"* | same `git show` |

The rewrite is phase 125's and it is the owner's, not an agent's: `docs/design/free-tier-copy.md:118-125` — itself modified in this working tree — records the strike and the replacement, and keeps the three old fragments struck rather than deleted. `:118` is the struck header, `:119` carries the note *"Revised Aug 26, 2026 by phase 125; all four strings owner-authored, approved Aug 26, 2026"*, and the three bullets are `:123`, `:124` and `:125`. **The bullet for this sentence is `:125`** — *"~~`Search, and a full export of the whole archive`~~ → `Search the whole archive, and export all of it whenever you want.`"* (An earlier draft of this document cited `:118-124`, which stops one line short of the only bullet that matters here.) It is pinned by value in `ios/Rascal/RascalTests/SettingsMembershipTests.swift:234-243`.

**The ambiguity is unchanged by the rewrite.** *"export all of it"* refers back to *"the whole archive"*, so the same two readings apply to the same phrase. (INFERRED, and offered as a reading rather than a finding: *"export all of it"* leans slightly harder on complete-not-partial than the old *"a full export of"* did, because *"all of it"* is a quantifier over the archive already named rather than a new noun phrase.)

**Two render sites, not one** — the first pass missed the second. Every anchor below moved again between the recheck of this document and this revision; these are the current ones:

- `PaywallSheet.freeBlock` (`PaywallSheet.swift:189`, called at `:108`), label at `:200`, the three lines at `:205-209`.
- `SubscriptionSection.reassurance` (`SubscriptionSection.swift:149`, rendered at `:80`), label at `:151`, the three lines at `:153-163`. Its doc comment says why it is there in every state: *"**Including when the household is subscribed** … a reassurance that appeared only on the free tier would read as a sales argument rather than a standing fact"* (`:141-144`).

So the sentence is on the paywall sheet **and** on the Settings membership card. `SubscriptionSection` itself is conditional in Settings (`SettingsScreen.swift:151`, `if let subscription`).

---

## 1. Does an export path exist at all?

**Yes, on both sides, and exactly one of each.** The sweep found no second path.

| Half | Where | Note |
|---|---|---|
| API route | `api/src/rascal/routers/export.py:26` — `"/{child_id}/export"` on a router with `prefix="/children"` (`:22`) | Registered once, at `api/src/rascal/main.py:142` |
| Service | `api/src/rascal/services/export.py` (535 lines), entered at `build_export` (`:457`) | |
| iOS entry point | `ios/Rascal/Rascal/Settings/ArchiveExport.swift:50` (`start(childId:)`), hitting `"v1/children/\(childId…)/export"` (`:121`) | |
| iOS UI | `ios/Rascal/Rascal/Settings/SettingsScreen.swift:428` `exportSection` → `:444` `exportRow` | Line numbers moved on this branch; §12 |

**The sweep, stated accurately this time.** `grep -rn "export" api/src/rascal/routers/` outside `export.py` returns **two** hits, not one: `social.py:264` (the social studio's `exported` asset *status*, a marketing-asset state machine, unrelated) and `prompts.py:140` (a comment reading *"card, in an export, and in a printed book, for as long as the archive exists"*). Neither is a route. **The conclusion holds — there is no second export route — but the first pass reported the grep result itself wrongly.**

**The `ShareLink` sweep, corrected.** `grep -rn "ShareLink" ios/Rascal/Rascal/` returns three hits and only one is a SwiftUI `ShareLink`: `SettingsScreen.swift:500`, the export's own share affordance. `GuardiansSection.swift:49` is `ShareLinkSheet(url: url)` — a `UIViewControllerRepresentable` wrapping `UIActivityViewController`, declared in the same file at `:159` — and `DesignSystem/SafariView.swift:12` merely names it in a comment. The first pass called `:49` a `ShareLink`; it is not.

There is no console export, no per-entry export, and no CLI script that produces one.

The route's own docstring states the reason it exists, and it is worth quoting because it is the same claim the paywall makes: *"an archive you cannot get out of the app is not an archive"* (`routers/export.py:3-4`).

---

## 2. What does it produce?

**A zip containing text and media both**, staged on disk rather than buffered in memory, plus a readable HTML layer.

The layout, quoted verbatim from `docs/api-contract.md:608-616` and confirmed against the writer (`services/export.py:409-452`):

```
manifest.json            format version, child, counts, media that could not be fetched
entries.json             every entry, oldest first, with its prompt, tags, and media rows
media/YYYY/MM/<id>.<ext> the objects themselves, foldered by occurred_at

index.html               the readable layer — double-click it, no server, no internet
assets/app.css           constant for every export; copied from the repo, never generated
assets/app.js            likewise
entries.js               entries.json's bytes as `window.RASCAL_ENTRIES = …;`
manifest.js              manifest.json's bytes as `window.RASCAL_MANIFEST = …;`
```

**That block is a quotation now; in the previous draft of this document it was not.** It was introduced as *"from the service's module docstring (`services/export.py:7-15`)"* and rendered fenced, and it is not that text. The docstring gives the same layout in its own words — *"`manifest.json` what this is, when it was made, what is in it / `entries.json` every entry, with tags, media references, and `deleted_at` / `media/YYYY/MM/<file>` the objects themselves, foldered by when they happened"* (`:7-9`) — and the two agree, but a synthesis rendered inside a fence and attributed to a file is exactly the failure §11 spends a table cataloguing. One thing the contract's line omits and the writer does not: the manifest also carries `scope` (`services/export.py:423`).

**Media is real bytes, not references.** `write_export` fetches every object from S3 (`:379`) and streams it straight into the zip a megabyte at a time (`:391-394`) — `STREAM_CHUNK_BYTES` is `1024 * 1024` (`:65`). The zip is assembled to a temp file (`staging_path`, `:497`) and read back in chunks by `stream_and_delete` (`:487-494`).

**The media path is streamed; the JSON payload is not.** The first pass wrote *"Nothing is held whole in RAM at any point"* — **that is false**, and correcting it is worth the space because the error came from trusting a docstring over the code. `services/export.py:30` does say *"Nothing is ever held whole in RAM"*, but `:409` serializes every entry into one `bytes` object, and the code's own comment three lines above concedes it: *"would double the peak memory of **the one part of this endpoint that is not already streamed**"* (`:406-408`). The object is released immediately (`del entries_bytes`, `:412`) after being written into both `entries.json` and `entries.js`, which is precisely why it is serialized once rather than twice. **The accurate statement: media never lands in memory whole; the entries JSON does, once, for both containers.** The module docstring overstates by its own file's admission.

**A dead upload does not fail the export.** A `ClientError` on one object is logged, recorded in `stats.missing_media`, and skipped (`:380-388`); that media row then keeps its metadata and loses its `path` so the manifest never points at a file that is not there (`:399-404`). The comment is the policy: *"one missing photo must not cost you the other seventeen years"* (`:381-382`).

**The HTML layer is the same bytes, not a second export.** `entries.js` is `entries.json` with `window.RASCAL_ENTRIES = ` prepended and `;` appended (`_as_script`, `:341-362`), because a page opened from `file://` may not `fetch()` a file beside it but may load one with a `<script>` tag (`:22-24`). The escaping is three JSON-identical substitutions (`</`, U+2028, U+2029) so a body somebody typed cannot close the script tag.

The zip is complete but **not exhaustive of every column.** Entries carry `occurred_at`, `created_at`, `updated_at`, `child_age_months`, `title`, `body`, `entry_type`, `unlock_at_age`, `deleted_at`, `is_deleted`, prompt, tags and media (`_entry_json`, `:179-236`). Media rows carry twelve fields — `id`, `kind`, `path`, `s3_key`, `bytes`, `duration_seconds`, `captured_at`, `transcript`, `caption`, `upload_status`, `deleted_at` and **`is_deleted`** (`:217-235`; the first pass enumerated eleven and read as exhaustive, omitting `is_deleted` at `:232`) — but **not** the media row's own `created_at` and `updated_at`, which exist on the model (`models/entry.py:153-154`). That is a note, not a defect: `captured_at` is the media analogue of `occurred_at` and it is present.

---

## 3. Is either half gated? Does any entitlement check touch export or search?

**No gating anywhere, on either half, on either side of the wire.** Both are free and complete, exactly as D2-as-reversed and D3-as-narrowed require.

### 3.1 The export half

**Server.** The route's only dependency is `child_access("parent")` (`routers/export.py:60`). That resolves to `require_child_access` (`deps.py:186`), which reads one `Guardian` row and checks `revoked_at IS NULL` (`:193-198`) and the role (`:202-203`), then loads the child and returns (`:210`). There is **no** entitlement read on the path: `grep -n "entitle" api/src/rascal/deps.py` returns exactly one hit, and it is a comment about family-level entitlement on the *unrelated* `require_family_access` (`deps.py:217`).

**Client.** `exportSection` is rendered unconditionally at `SettingsScreen.swift:152`. It sits *outside* every `if let` guard around it — `GuardiansSection` at `:146-148` and `SubscriptionSection` at `:151` are both conditional; the export is not. `ArchiveExport.swift` names no entitlement, no tier and no paywall anywhere in its 397 lines.

**So an entry created while subscribed and an entry created on the free tier are byte-identical to the export.** `_load_everything` selects on `child_id` and, optionally, a date window — nothing else (`services/export.py:254-271`). There is no author filter, no tier filter, no media-kind filter. A household that subscribed, uploaded video, and lapsed gets that video in its free export.

**That last sentence is true today and it is time-bound, which the previous drafts of this document stated flatly and should not have.** It is the load-bearing claim of the whole audit, so the expiry is worth naming:

- **What is read.** `write_export` reaches every object with a single `client.get_object` (`services/export.py:379`) and catches `ClientError` into `stats.missing_media`, skipping the object and continuing (`:380-388`); the row then loses its `path` (`:399-404`). There is no restore, no retry, no second storage class, and no `storage_tier` anywhere on the path.
- **What D3 promises.** *"At **day 90 lapsed** original media moves to the Tigris Archive tier while thumbnails stay hot … Full-resolution retrieval then needs a restore of about an hour or an active subscription"* (`docs/decisions.md:31`).
- **Why the two do not collide yet.** They cannot: the tier move is unbuilt. `api/src/rascal/schemas/family.py:203-207` says so in the schema that reports it — *"**A constant `hot` today**: D3's move to the Tigris Archive tier at 90 days lapsed is phase 38, `media` has no `storage_tier` column yet … It is not a read."*
- **The consequence, marked INFERRED.** If phase 38 lands without touching this file, a plain `get_object` against a cold object raises `ClientError`, which this code already treats as a dead upload — so a lapsed household's originals would land in `missing_media` and the export would come back *complete, well-formed and quietly short of its photographs*. That is a reading of boto3's behaviour and of the breadth of the `except ClientError`, not something observed: no Archive-tier object exists to test against, and no export was run.

**This is the same shape §3.4 raises about tests** — correct today by the absence of the thing that would break it — and it is on the audit's own central claim rather than on its test coverage. Reported, not proposed; it belongs to phase 38.

### 3.2 The search half — the audit the first pass never ran

The audited sentence has two halves. The first pass audited only the export half while asserting *"Everything else that sentence promises is true"*. **It is true, and here is the evidence.**

**Server: `GET /entries?q=` carries no entitlement check of any kind.** All VERIFIED-BY-READING:

| Check | Evidence |
|---|---|
| The route | `api/src/rascal/routers/entries.py:88-89`, `@router.get("/entries", …)` |
| `q` is the search parameter | `:117-123` — *"Full-text search over title, body, caption, and transcript. Words are stemmed … Supports \"exact phrase\" and -excluded."* |
| Its **only** access dependency | `:126` — `access: ChildAccess = Depends(child_access_from_query("viewer"))` |
| That dependency's whole body | `deps.py:262-272` — it resolves `child_id` from the query string and calls `require_child_access(…, "viewer")`. Nothing else. |
| No entitlement token in the router | `grep -n "entitle\|tier\|has_access\|access_for\|premium\|subscri" api/src/rascal/routers/entries.py` → **zero hits** |
| No entitlement token in `deps.py` | one hit, `:217`, the `require_family_access` comment above |
| No entitlement in the service either | `grep -rln "entitled\|entitlement" api/src/rascal/services/` lists **ten** files — `admin_metrics`, `app_store_events`, `app_store`, `grants`, `guardians`, `membership`, `notifications`, `scheduler`, `sync`, `today` — and `services/entries.py` is **not** among them. (An earlier draft said fourteen here. Fourteen is the combined `routers/` + `services/` count reported in §12: those ten plus `admin.py`, `families.py`, `today.py`, `webhooks.py`.) |
| The query itself | `search_statement` (`services/entries.py:590`) builds the `tsquery`, the rank expression and the three-column keyset. Its whole clause list is `[*_filters(child_id, before, after, entry_type, tag, sealed), search.matches(tsq)]` (`:611`), and `_filters` (`:487-522`) contributes `child_id`, `deleted_at IS NULL`, and the optional `before`/`after`/`type`/`sealed`/`tag` — **no tier, no entitlement, no date ceiling**. (An earlier draft named a `_search_query` at `:593-…`; there is no such symbol, and `:593` is the `query: str` parameter. It also stopped `_filters` at `:509`, the closing paren of the `sealed` clause, which cuts off the `tag` clause at `:510-521` and the `return` at `:522`.) |

Which routers *do* read entitlement: `admin.py`, `families.py`, `today.py`, `webhooks.py`. `today.py` is the only one that gates a parent-facing read, and it locks *slots* — `locked_slots_for(on, entitled=…)` at `:113-115` — the day, not the archive. `/sync` is deliberately ungated and says so in a comment (`services/sync.py:128`).

**Client: search is offered unconditionally.** `TimelineSearchModel` is constructed in the timeline's `.task` with no condition (`ios/Rascal/Rascal/Timeline/TimelineScreen.swift:96-99`), and the field renders whenever that model exists (`:273-276`, `searchField` defined at `:317`, `TextField("Search the archive", …)` at `:323`). `grep` for `entitle|subscri|paywall|locked|tier` returns **nothing** in either `TimelineScreen.swift` or `TimelineSearchModel.swift`. (Case-sensitively. Run with `-i` it returns one hit, `.typeRole(.screenTitle)` at `TimelineScreen.swift:295`, because *screenTitle* contains *enTitle* — a false positive, not a gate.)

**And search is what the decision names.** D3 as narrowed lists it explicitly: *"A free household keeps unlimited text and `did_it` entries, the 100-photo lifetime cap, full export, full-text search, and **every entry it already has**"* (`docs/decisions.md:31`).

**One scoping note, for honesty rather than as a defect:** search is per child (`Entry.child_id == child_id`, `services/entries.py:495`) and excludes soft-deleted rows (`:495`, and the route says so at `:95-96`). So *"search the whole archive"* is subject to the **same** one-child reading as the export half — the two halves of the sentence stand or fall together, which is itself an argument for treating the phrase as one settled term of art rather than two separate promises (INFERRED).

### 3.3 What the decisions require

The code and the decisions agree rather than merely coexisting. **`docs/decisions.md:30` is the D2 row, and its header is struck**: *"~~D2 — The free tier is the prompts, not the storage~~ — **REVERSED Aug 21, 2026 by the owner**"*. The first pass wrote *"D2 reads…"* with no mention of the reversal, which is loose in a document otherwise careful about strikes. **The clause relied on survives the reversal verbatim, twice in the same row** — *"full export always free and complete"* — and the row says so in terms: *"The storage half of the bargain did not change; the prompt half did."* D3 at `:31` states the operative test: *"If a change would make an existing entry unreadable, unexportable or unsearchable on a free tier, it is wrong."*

**On the D3 quotation above.** In §3.2 it is reproduced with the emphasis the source carries: `decisions.md:31` bolds **every entry it already has** and nothing else in that clause. An earlier draft of this document moved the bold onto *full-text search* — the phrase it wanted the reader to notice. That is an alteration of a quotation, small and in the document's own favour, which is the kind this file otherwise exists to catch.

### 3.4 One gap worth naming, since this is the claim's load-bearing property

`api/tests/test_export.py` has **26** tests (`grep -c 'def test_'` = 26, no `parametrize` in the file — the first pass said 27) and **none of them pins entitlement-independence.** `grep -n "lapsed\|entitle\|free\|tier" api/tests/test_export.py` returns nothing. **`api/tests/test_search.py` is the same**: the identical grep returns nothing there either. The behaviour is correct today by virtue of no gate existing rather than by a test that would fail if somebody added one. Compare `test_tier_has_exactly_one_writer` (`api/tests/test_app_store.py:854`), which exists precisely to keep an invariant of this kind from drifting. Reported, not proposed.

---

## 4. Is the originating prompt in it?

**Yes — the prompt body, kind, cadence, completion mode and theme, attached to each entry.**

`_prompts_for` collects the `assignment_id` of every entry, joins `Assignment` to `Prompt`, and returns a map (`services/export.py:277-287`). Its docstring states the purpose: *"The originating prompt per entry, so the export says what was asked, not just answered"* (`:278`). `plan_export` then passes `prompts.get(entry.assignment_id)` into each record (`:299`), and `_entry_json` renders the nested object (`:196-207`).

It survives into the readable layer too. `export_viewer/assets/app.js:774` writes the label *"The prompt"* above the quoted body, and `:325` folds the prompt body and theme into the viewer's own search index.

This is pinned by a test whose name and docstring say why it matters: `test_the_originating_prompt_is_exported_next_to_the_answer` — *"A `did_it` entry with no artifact is meaningless without the mission it completed"* (`api/tests/test_export.py:306-309`), asserting `did_it["media"] == []` (`:316`) and `did_it["prompt"]["body"] == "Get on the floor for ten minutes. No phone."` (`:317`). That is CLAUDE.md rule 4 tested from the export's side.

One detail the auditor should not mistake for a bug: **the server ships prompt bodies with their pronoun tokens intact and does not render them.** `manifest.child` carries `pronouns` (`:315`) for exactly that reason, with the comment saying so at **`:311-314`** (`:310` is `"family_timezone"`), and `app.js` substitutes at read time — `renderTokens` is defined at `:172` and called at `:325`, **`:589`** and **`:775`**. (The first pass gave `:588` and `:774`; those are `var quote = el(…)` and the *"The prompt"* label respectively.) That is consistent with the rule that the server never renders.

---

## 5. `occurred_at` versus `created_at` — CLAUDE.md rule 3

**Respected, not flattened, in all four places it could have been flattened.**

1. **Both are emitted, separately.** `"occurred_at": _iso(entry.occurred_at)` and `"created_at": _iso(entry.created_at)` are adjacent keys (`services/export.py:184-185`), with `updated_at` beside them (`:186`).
2. **Selection is by `occurred_at`.** Both scope bounds compare against `Entry.occurred_at` (`:268`, `:271`), and ordering is `Entry.occurred_at.asc(), Entry.id.asc()` (`:261`). The docstring states the rule: *"a photo taken in December and uploaded in January belongs to December's book. Backdating is a first-class flow here and this is where it shows"* (`:250-252`).
3. **Media is foldered by when the moment happened**, not when the file was uploaded: `_media_path` interpolates `entry.occurred_at` (`services/export.py:175`).
4. **The date window is resolved in the child's zone, not UTC.** `local_day_window(…, child.family_timezone)` on each bound (`:267`, `:270`), which is CLAUDE.md rule 1 applied to a range: the server owns what day it is. `ExportScope`'s docstring spells out the failure it prevents — an 8pm Dec 31 entry in Detroit stored as Jan 1 UTC, filed in the wrong year, *"which for a book printed once a year is a mistake nobody catches until it is on paper"* (`:94-98`).

`api/tests/test_export.py:567` pins the fourth point by name: `test_the_boundary_is_the_familys_midnight_and_not_utc`.

---

## 6. Is it reachable from the UI?

**Yes. Settings → "Keep a copy", ungated, unhidden, four states.** Every line number in this section moved on this branch and has been re-read.

| Step | Site |
|---|---|
| Section rendered, unconditionally | `SettingsScreen.swift:152` (`exportSection`) |
| Section defined, titled *"Keep a copy"* | `SettingsScreen.swift:428-432` |
| The idle card and its tap | `SettingsScreen.swift:447-466` — `Button { export?.start(childId: childId) }` at `:448` |
| Model constructed on appear | `SettingsScreen.swift:187` — `if export == nil { export = ArchiveExport(api: session.api) }` |
| Request issued | `ArchiveExport.swift:121-124` |
| Result handed to the share sheet | `SettingsScreen.swift:500` — `ShareLink(item: url)` |

The card's own copy is *"Export the archive"* (`:450`) over *"Every entry, photo and recording, as a zip you can keep forever."* (`:453`). It is drawn in `Color.terracotta` as a card rather than a row, deliberately — *"which is what makes the export read as a keepsake instead of a menu item"* (`:436-437`).

All four states are built: `.idle` (`:447-466`), `.running(fraction:)` with a real progress bar and a Cancel (`:468-489`), `.ready(url:bytes:)` with `ShareLink` and Done (`:491-510`), and `.failed(message)` with Try again (`:512-525`). The progress bar is a measurement rather than an animation because the server sends an exact `content-length` — it can, because the zip is fully assembled on disk before streaming begins (`routers/export.py:99-101`).

**Two honest observations about reachability, neither of which falsifies the paywall claim:**

- **A viewer guardian sees the card and cannot use it, and the refusal is a 403.** The route requires `parent` (`routers/export.py:60`; pinned by `test_a_viewer_cannot_walk_off_with_the_whole_archive`, `tests/test_export.py:401`, asserting `403` at `:413`). `ErrorCode.NOT_AUTHORIZED` maps to **403**, not 401 (`api/src/rascal/errors.py:72`) — the first pass said 401, and **the difference is behavioural, not cosmetic**: 401 is the refresh-and-retry branch in the client (`ArchiveExport.swift:129-133`, `if outcome.status == 401 { … api.refreshSession() … }`), a materially different path from the `.notAuthorized` message at `:209-210`. The client has the role available — `ChildResponse.role` is decoded at `RascalAPI.swift:130` (`:129` is `let ageMonths: Int`) and `SettingsScreen` holds a `ChildResponse?` (`:83`) — but `exportRow` never consults it. The failure is handled gracefully rather than rudely: `ArchiveExport.explain` maps `.notAuthorized` to *"Only a parent on this archive can export it."* So it is a tap that explains itself, not a crash. **INFERRED**, from the code paths: no running app was observed.
- **Leaving the tab cancels an in-flight export** (`SettingsScreen.swift:236`, `.onDisappear { export?.cancel() }`), and the partial file goes with it — *"half an archive is not a smaller archive, it is a corrupt zip"* (`ArchiveExport.swift:87-88`).

---

## 7. The three specific checks

### 7.1 Soft-deleted entries — **included, and marked**

`_load_everything` applies **no** `deleted_at IS NULL` filter (`services/export.py:254-271`) — one of the two deliberate exemptions from the standing read-path rule, alongside `/sync`. Each record carries both `deleted_at` and a derived `is_deleted` boolean (`:194-195`), the count goes into the plan as `deleted_entries` (`:319`) and into the manifest at **`:426`** (the first pass cited `:427`, which is `"media": stats.media,`), and `manifest.notes` says so in words: *"entries.json contains every entry, including soft-deleted ones."* (`_scope_notes`, `:155`).

The docstring gives the reason and, more usefully, forecloses the tempting half-measure: *"Scoping answers which days, never which rows on those days — an export that dropped deletions would stop being a copy, and doing that silently on the scoped path only would be worse than doing it everywhere"* (`:244-247`). Pinned twice: `test_the_export_contains_every_entry_including_the_deleted_one` (`tests/test_export.py:221`) and `test_a_deleted_entry_inside_the_range_still_comes_out` (`:648`).

### 7.2 Sealed letters — **exported in the clear**

`unlock_at_age` is exported as data with the seal not enforced, and the comment states the position: *"Sealed letters carry this. Exported in the clear — this is your copy of your own archive, and an export you cannot read is not a backup."* (`services/export.py:191-192`; `:193` is the field itself). `manifest.notes` repeats it (`:434`), and `test_a_sealed_letter_exports_in_the_clear_with_its_unlock_age` pins it (`tests/test_export.py:247`).

### 7.3 The child's avatar — **not in any export**

`children.avatar_key` exists on the model (`api/src/rascal/models/child.py:26`). `plan_export` builds `manifest.child` from `id`, `name`, `birthdate`, `family_timezone` and `pronouns` — and nothing else (`services/export.py:306-316`). `grep -i avatar` returns **zero hits** in both `services/export.py` and `ArchiveExport.swift`.

**This is deliberate and already disclosed to the parent — in the app, not only in a comment.** The disclosure the *parent* sees is `ChildPhotoCopy.footnote`: *"It isn't a profile picture anywhere, and it isn't part of an export."* (`ios/Rascal/Rascal/Settings/ChildPhotoField.swift:510`), rendered on the field at `:111`. The first pass asserted the disclosure was made but cited only the developer-facing doc comment at `:434-436`, which corrects a design import that had claimed otherwise: *"'It's never part of an export unless you ask.' There is no such switch. `ArchiveExport` names no avatar at all, so the photo is not in an export, full stop — and `footnote` says the thing that is true rather than the softer thing that is not."*

It is held in place by a test that reads the source file and asserts the word does not appear in it — `theExportStillHasNoAvatarInIt` (`ios/Rascal/RascalTests/SettingsV2Tests.swift:1031-1046`), whose docstring names the mechanism: *"the day it does, this fails and the sentence gets rewritten — which is the only mechanism that stops a true line from quietly becoming a false one"* (`:1028-1030`).

Whether a portrait of the child belongs in *"the whole archive"* is a product judgment, not a code question. It is listed at the end as a smaller second call because the app already tells the truth about it.

---

## 8. One child at a time — the mechanism, and the reading it does not settle

### 8.1 The mechanism (VERIFIED-BY-READING, and not in dispute)

**The export is scoped to one child, and the client can only ever ask for the one currently selected.**

- The route is `/children/{child_id}/export` (`routers/export.py:26`), and the whole read is `Entry.child_id == child.id` (`services/export.py:256`).
- The zip is named for that child — `vellum-<child>-20260804.zip` (`filename_for`, `:504-535`).
- iOS passes `childId` (`SettingsScreen.swift:448`), a `let` on the screen (`:24`), handed down from `RootView.childId` (`ios/Rascal/Rascal/App/RootView.swift:15`) at the `SettingsScreen(` call that opens at `:518` — `childId:` is `:519`, `session:` is `:520`.
- `RootView` is constructed once per child by `OnboardingGate` with a single `child.id` (`ios/Rascal/Rascal/Onboarding/OnboardingGate.swift:949-951`).
- Switching is a Today-screen affordance, not a Settings one: `onSwitchChild` is supplied only when `session.canSwitchChild` (`OnboardingGate.swift:959`), and `ChildSwitcherPill` documents the rule that *"One child and a chevron is a control that lies"* (`ios/Rascal/Rascal/Today/ChildSwitcherPill.swift:11-12`).
- `SettingsScreen.childrenSection` offers exactly one row, *"Add a child"* (`:368-374`). There is no "export everything" affordance and no list to pick from.

So a two-child household's path to both archives is: export child A, switch child on Today, return to Settings, export child B — two zips, two `manifest.json` files, no artifact that is the household. (The absence of any other affordance is **INFERRED** from search rather than from exhaustive reading of every view; the positive claims above are read.)

### 8.2 The reading — flagged, not resolved

**The open question is what *"the whole archive"* means in this sentence, and this repository answers it consistently in one direction.**

**What the sweep actually returns, said plainly.** `grep -rn "whole archive" api/ ios/ docs/` returns dozens of hits — roughly forty-five outside `docs/archive/` and `docs/App-Views/`, most of them incidental (sync cursors, paging budgets, `recompute-ages`, test names). The table below is **a selection, not the sweep's output**: it is the subset where the phrase is used as a *term* carrying a contrast, and it was described as *"six places"* in the previous draft, which read as an enumeration of the whole result and was not one. Two on-point sites the previous draft omitted are restored at the bottom. **What matters is the direction, and on that the sweep is one-sided: no site anywhere in the tree uses *"the whole archive"* to mean household-wide.** Every row was re-read for this pass.

| Site | Text | What it contrasts |
|---|---|---|
| `api/src/rascal/services/export.py:91-92` | *"`to` with no `from` is 'everything up to'. **Neither is the whole archive**, which is what every caller before this got and still gets by sending nothing."* | complete vs. **scoped** — inside `ExportScope`, per child |
| `api/src/rascal/services/export.py:244` | *"Soft-deleted rows stay in, exactly as they do for the whole archive."* | complete vs. scoped |
| `api/src/rascal/services/export.py:293` | *"`scope` narrows which days are read; it defaults to the whole archive."* | complete vs. scoped |
| `api/src/rascal/routers/export.py:30` | *"Defaults to the whole archive; `from` and `to` narrow it…"* | complete vs. scoped |
| `docs/api-contract.md:602` | *"Omit both for the whole archive, which is what every caller before this got and still gets."* | complete vs. scoped |
| `ios/Rascal/Rascal/Settings/ArchiveExport.swift:3` | *"Downloading the whole archive as a zip."* | the per-child download, named whole |
| **`ios/Rascal/Rascal/Timeline/TimelineScreen.swift:205`** *(added)* | *"**Search reads the whole archive.** Combining a filter chip with a query is explicitly out of scope, and narrowing the query behind it would silently drop results the server ranked and returned."* | complete vs. **filtered** — and it is the *search* half of the audited sentence, the single most on-point site the previous draft left out |
| **`ios/Rascal/Rascal/Settings/SyncPullSection.swift:101`** *(added)* | *"The next sync reads your whole archive from the beginning. It takes longer and changes nothing that is already here."* | complete vs. incremental — **and it is user-facing**, which makes it the closest thing to a precedent for how a parent meets the phrase in this app |

The code draws the same contrast structurally, not only in prose: `manifest.scope.complete`, and `_scope_notes` writes **"THIS IS A PARTIAL ARCHIVE"** into a scoped manifest precisely so *"a partial archive must never be mistakable for a whole one"* (`routers/export.py:36-37`). Two tests carry the term in their names on the complete-vs-partial axis: `test_an_unscoped_export_still_says_it_is_the_whole_archive` (`:522`) and `test_a_scoped_manifest_refuses_to_claim_it_is_whole` (`:621`).

**So the reading this repository's own vocabulary supports is *complete rather than partial*, per child — and under that reading `MembershipCopy.stayFree[2]` is TRUE**, and so is its search half, and nothing needs to change. The competing reading — *"the whole archive" = everything this household has* — is available to a parent who has two children and has never read the source, and that is a real risk, but it is a copy risk to weigh, not a defect to file. **It is the owner's call and it is not made here.**

**Two things the first pass got wrong on the way to its verdict, both fixed:**

1. **The api-contract citation was inverted.** The first pass wrote that `docs/api-contract.md:595-597` *"records that a household-scoped shape was **considered and replaced** for guardians"*, and leaned on that to conclude the child-scoped export was a deliberate choice. **The file records the opposite.** `:592` strikes `~~POST /children/{id}/guardians~~`; `:593-597` explain that guardians are invited through `POST /families/me/invites` because *"an invite belongs to the household rather than to one child"*, and that the strike is kept *"so the next reader sees that **the child-scoped shape was considered and replaced**"*. The only cited support pointed the other way. The narrower true statement, and all this section needs: **the export route has been child-scoped since it was written, and the contract documents it that way at `:599`** — whether that was weighed against a household shape is not something this file records either way.
2. **The footnote is conditional, so "the sheet contradicts itself by two lines" overstates what a parent sees.** `MembershipCopy.footnote` — ~~*"One membership covers the whole family — every child, both parents."*~~ **replaced Aug 26, 2026 by the owner, after this audit was written, with *"One price covers everyone in the house — every parent, every child."*; see `MembershipCopy.footnote`, which carries the string and its history** — renders only inside `if canOffer { renewalTerms; footnote }` (`PaywallSheet.swift:123-126`), and `canOffer` is true only when `model.phase == .ready` (`:375-378`). By this file's own note, no subscription product exists in App Store Connect and no sandbox transaction has ever been made (`MembershipCopy.swift:162-165`), so the footnote is **very likely not on screen at all today** (INFERRED — no running app was observed; what is read is the guard and the note). ~~**The vocabulary observation survives and is still worth acting on**: the sheet uses *the whole family* for the household and *the whole archive* for one child, and if the owner ever wants the two lines to sit together they should use one vocabulary.~~ — **overtaken by the replacement above, which is the whole point of recording it.** The footnote now says *everyone in the house*, so the sheet no longer says *the whole family* at all, and the collision this paragraph named is between *the house* and *the whole archive*. **The observation is unchanged in substance**: two different scopes, two different vocabularies, one screen. What does not survive is the claim that a parent is currently reading both.

---

## 9. Summary table

| # | Question | Answer |
|---|---|---|
| 1 | Does an export path exist? | ✅ **Yes.** One route (`routers/export.py:26`), one service, one iOS entry point. No second path anywhere. |
| 2 | Text only, or media too? | ✅ **Both.** Zip: `entries.json` + every S3 object under `media/YYYY/MM/`, plus a `file://`-readable HTML viewer. |
| 3 | **Search** — gated by entitlement? | ✅ **No.** `GET /entries?q=` takes `child_access_from_query("viewer")` and nothing else (`routers/entries.py:126`); zero entitlement tokens in the router, the service or the iOS search model. D3 names full-text search as free (`decisions.md:31`). |
| 4 | **Export** — free-tier *and* previously-subscribed entries? | ✅ **Both, ungated.** No entitlement check on the route (`:60` is `child_access("parent")` only) or on the iOS section (`SettingsScreen.swift:152`). ⏳ **Time-bound**: a lapsed household's *media* survives in the export only while the Archive-tier move is unbuilt — see §3.1. |
| 5 | The originating prompt? | ✅ **Yes.** Body, kind, cadence, completion mode, theme (`services/export.py:196-207`), pinned by test. |
| 6 | `occurred_at` vs `created_at`? | ✅ **Both preserved, selection and foldering by `occurred_at`, window resolved in the family's zone.** |
| 7 | Reachable from the UI? | ✅ **Yes.** Settings → *Keep a copy*, unconditional, four states. |
| — | Soft-deleted entries? | ✅ **Included and marked `is_deleted`.** |
| — | Sealed letters? | ✅ **Exported in the clear**, `unlock_at_age` retained. |
| — | Child avatar? | ❌ **Absent** — deliberately, and disclosed to the parent at `ChildPhotoField.swift:510`. |
| — | All children, or one? | ⚠️ **One at a time.** N children → N exports; search is per child too. **Whether that makes *"the whole archive"* untrue is a reading, not a finding** — see §8.2. |
| — | Entitlement-independence pinned by a test? | ❌ **No**, for either half: `test_export.py` and `test_search.py` both return nothing for `lapsed\|entitle\|free\|tier`. |

---

## 10. For the owner — two calls, neither of them mine

**(1) *"the whole archive"* and multi-child households — and the recommendation is that this may need no action.** The mechanism is settled: one route, one child, no household-wide affordance. The question is only what the phrase promises, and **this repository has used it to mean *complete rather than partial* at every site where the phrase carries a contrast, for months** (§8.2), which is the reading under which the line is true as written. If the owner agrees, the right outcome is **no change to the copy and no change to the export** — and, optionally, a note in `docs/design/free-tier-copy.md` recording that the phrase was checked and means complete-not-partial, so the next audit does not re-open it. If the owner reads it the other way, then either the export grows a household shape (which has to decide what `manifest.child` becomes and what the filename is) or the words change. Both are real options; neither is obviously right; neither is scoped or costed here.

**(2) The avatar.** Currently out, deliberately, and the app says so at `ChildPhotoField.swift:510`. If (1) resolves as *no change*, this needs no action at all. If the answer is that *"the whole archive"* is a promise to keep literally, then the portrait of the child is the one obvious thing an archive of a childhood does not contain.

**Two things that are findings rather than calls**, and the only items here an agent could act on without a decision:

- **Neither half's entitlement-independence is pinned by a test** (§3.4). Both are correct today by the absence of a gate rather than by anything that would fail if somebody added one.
- **The export's media path has no story for cold storage**, and D3 already promises one at day 90 lapsed (§3.1). It cannot break today — `media` has no `storage_tier` column (`schemas/family.py:203-207`) — but a `get_object` that meets an archived object raises `ClientError`, which this code already treats as a dead upload and skips into `missing_media`. It belongs to phase 38, and it is the same correct-by-absence shape as the item above, sitting on the claim this whole audit is about.

Both reported, neither proposed.

---

## 11. What this pass corrected in the first one

| # | First pass said | The tree says |
|---|---|---|
| 0 | The claim *"is false in one respect"* — headline, stated as verified fact | An interpretation of ambiguous copy. The mechanism is right; the verdict is a reading, and the repository's own vocabulary supports the opposite one (§8.2). |
| 1 | *"27 tests"* in `test_export.py` | **26** (`grep -c 'def test_'`; no `parametrize`) |
| 2 | `api-contract.md:595-597` records *a household-scoped shape was considered and replaced* | Inverted. `:592-597` records the **child-scoped** shape being struck and replaced by the household one, for guardians |
| 3 | A viewer *"would receive a 401 on tap"* | **403** (`errors.py:72`; `test_export.py:413`). 401 is the refresh-and-retry branch, `ArchiveExport.swift:129-133` |
| 4 | *"Nothing is held whole in RAM at any point"* | False for the JSON payload (`export.py:409`), as the code's own comment concedes (`:406-408`). The module docstring at `:30` is where the error came from |
| 5 | `deleted_entries` at `:319`, **`:427`** | `:319` ✓; the manifest key is **`:426`** — `:427` is `"media"` |
| 6 | `ChildResponse.role` at `RascalAPI.swift:129` | **`:130`**; `:129` is `let ageMonths: Int` |
| 7 | Only other `export` hit in `routers/` is `social.py:264` | There are **two**: `social.py:264` and `prompts.py:140`. Conclusion unaffected |
| 8 | *"the only other `ShareLink` is … `GuardiansSection.swift:49`"* | `:49` is `ShareLinkSheet`, a `UIViewControllerRepresentable` at `:159`. The only SwiftUI `ShareLink` in `ios/` is `SettingsScreen.swift:500` |
| 9 | *"`footnote`, rendered on the same sheet"* → *"contradicts itself by two lines"* | Conditional on `canOffer` (`PaywallSheet.swift:123`, `:375-378`), which requires `.ready`; per `MembershipCopy.swift:162-165` there is no product, so it is likely not on screen. Vocabulary point survives; the framing does not |
| A | `renderTokens` at `:325`, `:588`, `:774` | `:325`, **`:589`**, **`:775`** |
| B | Pronouns comment `:310-314` | **`:311-314`**; `:310` is `"family_timezone"` |
| C | Sealed-letter comment `:191-193` | **`:191-192`**; `:193` is the field |
| D | Entry dict `:179-235` | closes at **`:236`** |
| E | `RootView.childId … passed at :519-520` | call opens at **`:518`**; `childId:` `:519`, `session:` `:520` |
| F | `RootView.swift`, `ChildSwitcherPill.swift`, `OnboardingGate.swift` by bare name | `ios/Rascal/Rascal/App/`, `…/Today/`, `…/Onboarding/` |
| G | Media field list read as exhaustive | omitted **`is_deleted`** (`:232`) |
| H | *"Everything else that sentence promises is true"* — search never audited | **§3.2 added.** Ungated, with evidence |
| I | *"already disclosed to the parent"*, citing a doc comment | The parent-facing disclosure is `ChildPhotoCopy.footnote` (`ChildPhotoField.swift:510`), rendered at `:111` |
| J | *"D2 reads…"* | The **D2 row header is struck** — *"REVERSED Aug 21, 2026"* (`decisions.md:30`). The quoted clause survives the reversal verbatim, twice |
| K | Every `SettingsScreen`/`PaywallSheet`/`MembershipCopy` anchor | **All moved** on this branch; re-read and re-cited (§0, §6) — and they moved **again** between that pass and this revision |
| L | One render site for the audited sentence | **Two** — `PaywallSheet.freeBlock` and `SubscriptionSection.reassurance` (§0) |

---

## 12. Verification honesty

**What this pass is.** A read-only pass over the working tree on `ios/phase-124-submission-compliance`, HEAD `d7ece87`, **with uncommitted work in the tree**. `git status --porcelain` prints **sixteen lines — fourteen modified and two untracked**:

```
 M docs/blocked.md
 M docs/decisions-log.md
 M docs/design/design-conformance-110.md
 M docs/design/free-tier-copy.md
 M docs/roadmap-status.md
 M ios/Rascal/Rascal/Settings/SettingsScreen.swift
 M ios/Rascal/Rascal/Subscription/MembershipCopy.swift
 M ios/Rascal/Rascal/Subscription/MembershipPresentation.swift
 M ios/Rascal/Rascal/Subscription/PaywallSheet.swift
 M ios/Rascal/Rascal/Subscription/SubscriptionModel.swift
 M ios/Rascal/Rascal/Subscription/SubscriptionSection.swift
 M ios/Rascal/RascalTests/MembershipTests.swift
 M ios/Rascal/RascalTests/SettingsMembershipTests.swift
 M ios/Rascal/RascalTests/SubscriptionTests.swift
?? ios/Rascal/Rascal/DesignSystem/SafariView.swift
?? ios/Rascal/RascalTests/SubmissionComplianceTests.swift
```

**The tree moved underneath every pass of this audit, including this one, and the count above is the third different answer.** The first pass's `git status` listed ten `ios/` paths; minutes later a second listed five `docs/` paths as well; the pass before this one recorded thirteen modified and two untracked; and a `git status --porcelain` run at the *start* of this revision printed **fifteen** lines while one run at the *end* printed **sixteen** — `ios/Rascal/RascalTests/MembershipTests.swift` appeared while this document was being corrected. Nothing was changed by this session; another session is editing the same checkout. `HEAD` was re-confirmed as `d7ece87` at both ends.

Three concrete symptoms, so this is not an abstract caution:

- `PaywallSheet.freeBlock` was cited at `:193` a pass ago and is at `:189` now; its label moved `:204` → `:200` and its three lines `:210-212` → `:205-209`. `canOffer` moved `:379-382` → `:375-378`, and the `if canOffer` guard `:127-130` → `:123-126`.
- `SubscriptionSection.reassurance` moved `:150` → `:149`, its label `:152` → `:151`, and its doc comment `:142-145` → `:141-144`.
- `SubmissionComplianceTests.noMembershipStringCarriesAToken` moved from `:245` to `:262`, and the strings it guards changed with it: it now covers `MembershipCopy.freeLabel`, the three `stayFree` lines, and `SubscriptionModel.restoreFound`, which currently reads **"Found it. Your membership is active."** (`SubscriptionModel.swift:539`).

**What "verified" means here, stated precisely.** Every `file:line` **cited in this document** was opened and re-read against the tree during this revision — that is the claim, and it is the one that was made too broadly before. It is **not** a claim that every line of every file was read: `services/export.py` was read across its cited regions rather than end to end, and the same goes for `routers/export.py`, `deps.py`, `routers/entries.py`, `services/entries.py`, `errors.py`, `app.js`, and the Swift files. A previous draft of this section said *"Every file:line in this document was re-read against that tree"* while four of its citations did not resolve; the sentence was true of the intent and false of the result, which is the same failure mode the rest of this document catalogues.

**What the independent recheck found in the previous draft, all applied here:**

| Kind | The previous draft said | Fixed to |
|---|---|---|
| Wrong symbol and line | `_search_query` at `services/entries.py:593-…` | `search_statement` at `:590`; clause list at `:611`. `:593` is the `query: str` parameter |
| Truncated range | `_filters` at `:487-509` | `:487-522`; `:509` closes the `sealed` clause, `tag` is `:510-521`, `return` is `:522` |
| Misattributed count | *"`grep -rln` over `services/` lists fourteen files"* | **ten**; fourteen is `services/` (10) + `routers/` (4), which is what this section reports |
| Range excludes its own subject | `free-tier-copy.md:118-124` for the strike and replacement | `:118-125`; the bullet for the audited sentence is **`:125`** |
| Inference as fact | the first pass *"silently overturned"* `phase-124-preflight.md:35-39` | **Withdrawn.** `:36-38` quotes the pre-phase-125 strings and `:39` answers a D2/D3 question. See the fourth paragraph at the top |
| Synthesis as quotation | §2's layout block, fenced and attributed to `services/export.py:7-15` | Now quoted verbatim from `api-contract.md:608-616`, with the actual docstring paraphrased and labelled as such |
| Curation as enumeration | *"in six places"* for the `"whole archive"* sweep | §8.2 now says the sweep returns dozens of hits, names the table as a selection, and adds `TimelineScreen.swift:205` and `SyncPullSection.swift:101` |
| Altered quotation | D3 quoted with `**full-text search**` bolded | `decisions.md:31` bolds `**every entry it already has**`; restored, and the alteration is named in §3.3 |
| Unflagged time-bound claim | *"A household that subscribed, uploaded video, and lapsed gets that video in its free export"* | Flagged in §3.1, in §9 row 4, and in §10 as the second finding |

**Verified by reading:** every file and line reference in this document, listed by the regions actually opened. `api/`: `routers/export.py:1-40`, `:55-65`, `:95-105`; `services/export.py:60-70`, `:88-115`, `:145-240`, `:239-275`, `:277-320`, `:341-370`, `:375-455`, `:485-535`, `:1-35`; `main.py:140-144`; `routers/entries.py:85-130`; `services/entries.py:483-525`, `:585-625`; `deps.py:184-220`, `:258-275`; `errors.py:68-76`; `models/child.py:24-28`; `models/entry.py:150-156`; `schemas/family.py:198-212`; `routers/today.py:111-117`; `services/sync.py:126-130`; `routers/prompts.py:140`; `routers/social.py:264`; `export_viewer/assets/app.js:170-175`, `:323-327`, `:586-592`, `:772-777`; `tests/test_export.py:304-320`, `:399-415`; `tests/test_app_store.py:850-858`. `ios/`: `ArchiveExport.swift:85-90`, `:118-135`, `:205-215`; `SettingsScreen.swift:20-28`, `:80-86`, `:144-156`, `:368-374`, `:426-530`; `MembershipCopy.swift:118-170`; `PaywallSheet.swift:105-132`, `:178-215`, `:296-330`, `:368-384`; `SubscriptionSection.swift:78-82`, `:140-165`; `TimelineScreen.swift:94-101`, `:203-210`, `:271-278`, `:315-325`; `SyncPullSection.swift:97-105`; `GuardiansSection.swift:47-51`, `:157-161`; `SafariView.swift:10-14`; `ChildPhotoField.swift:108-114`, `:430-440`, `:505-514`; `RootView.swift:12-18`, `:514-524`; `OnboardingGate.swift:945-962`; `ChildSwitcherPill.swift:8-14`; `RascalAPI.swift:126-133`; `SettingsV2Tests.swift:1026-1048`; `SettingsMembershipTests.swift:228-248`; `SubmissionComplianceTests.swift:255-270`; `SubscriptionModel.swift:509-541`. `docs/`: `api-contract.md:590-620`; `decisions.md:28-33`; `decisions-log.md:810-825`; `design/free-tier-copy.md:108-135`; `reports/phase-124-preflight.md:25-45`.

**Verified by running read-only commands:** the absence sweeps and the counts. `grep -c 'def test_' api/tests/test_export.py` → 26; `grep -c parametrize` → 0. `grep -n "lapsed\|entitle\|free\|tier"` over `test_export.py` and `test_search.py` → nothing in either. `grep -n "entitle\|tier\|has_access\|access_for\|premium\|subscri"` over `routers/entries.py` → nothing, over `deps.py` → one hit at `:217`. `grep -rln "entitled\|entitlement"` → **ten** files under `api/src/rascal/services/` and **four** under `api/src/rascal/routers/`, fourteen combined, with neither `entries.py` nor `export.py` among them in either directory. `grep -rn "whole archive"` across `api/`, `ios/`, `docs/` for §8.2. `grep -rn "export" api/src/rascal/routers/` and `grep -rn "ShareLink" ios/Rascal/Rascal/` for §1. `grep -i avatar` over `services/export.py` and `ArchiveExport.swift` → nothing. `grep -in "entitle"` over the two Timeline files → one false positive, `screenTitle`. `git status --porcelain` (twice, with different results — see above), `git rev-parse HEAD`, `git log -1`, `git show HEAD:…/MembershipCopy.swift`, and `git diff --stat` for §0 and the provenance above.

**Not run, and not claimed:** **no `xcodebuild`, no `pytest`, no `make test`, no `swift build`.** No export was performed against a running server and no zip was opened. Every statement about what a zip *contains* is a statement about the code that writes it and, where noted, about a test that asserts it — not about a file anybody has held. The test names and assertions cited throughout were read from source; **they were not executed by this pass**, so *"pinned"* here means *"a test exists that would fail"*, not *"a test was observed passing today"*. This matters more than usual on this branch: two of the tests cited (`SettingsMembershipTests.theReassuranceIsTheApprovedBlock`, `SubmissionComplianceTests.noMembershipStringCarriesAToken`) are themselves uncommitted and have not been run here.

**Inferences, marked as such where they appear and listed here:** (a) that a viewer-role guardian reaching Settings sees the export card and receives a 403 on tap is read off the code paths, not observed in a running app; (b) that the two-child household's only route to both archives is switch-and-repeat rests on an absence proved by search rather than by exhaustive reading of every view; (c) that `MembershipCopy.footnote` is not on screen today follows from `canOffer` requiring `.ready` plus the file's own note that no product exists — the guard is read, the App Store Connect state is not; (d) that *"export all of it"* leans harder on complete-not-partial than the string it replaced is a reading of English, offered as such; (e) that the two halves of the audited sentence stand or fall together on the one-child question follows from both being `child_id`-scoped, which is read, but the conclusion drawn from it is a reading; (f) that an Archive-tier object would fail `get_object` and land in `missing_media` (§3.1) is read off the breadth of the `except ClientError` and boto3's behaviour, not observed — no such object exists to test against.

**One thing this pass deliberately does not do:** decide §8.2. The evidence is laid out in both directions and the repository's own usage is named as supporting one of them. The sentence belongs to the owner, and `MembershipCopy.swift`'s own rule — copy is authored by the owner, not written into a view by an agent — is the reason an audit stops here.
