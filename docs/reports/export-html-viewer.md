# The readable archive: a static site inside the export zip

`GET /children/{id}/export` now carries a second layer in the same zip: `index.html`,
`assets/app.css` and `assets/app.js`, which open the archive by double-clicking, with no
server, no build step and no internet. They read `entries.js` and `manifest.js` — the same
bytes as the `.json` files with a variable assignment wrapped around them.

`entries.json`, `manifest.json` and `media/YYYY/MM/` are unchanged. **No API change was
needed:** the manifest already carried the birthdate.

Preflight is in `docs/reports/export-html-preflight.md`.

---

## 1. The observed entry object shape, and what the viewer consumes

Taken from a real export off a running API, not from `docs/api-contract.md`. The full
field-by-field table is in the preflight report; one entry verbatim:

```json
{
  "id": "1e4468ed-…", "child_id": "bd54e295-…", "assignment_id": "4ed1bd98-…",
  "author_id": "39034965-…",
  "occurred_at": "2026-04-16T21:30:00+00:00",
  "created_at":  "2026-08-11T23:25:17.287141+00:00",
  "updated_at":  "2026-08-11T23:25:17.363009+00:00",
  "child_age_months": 58,
  "title": null, "body": "Caught it.", "entry_type": "photo",
  "unlock_at_age": null, "deleted_at": null, "is_deleted": false,
  "prompt": {"id": "59b511f4-…", "kind": "photo", "cadence": "daily",
             "completion_mode": "media",
             "body": "Photograph his shoes by the door.", "theme": "everyday-ordinary"},
  "tags": [{"id": "d8d74b27-…", "name": "making", "source": "user", "deleted_at": null}],
  "media": [{"id": "3e77c92b-…", "kind": "photo",
             "path": "media/2026/04/3e77c92b-….png", "s3_key": "children/…/3e77c92b-….png",
             "bytes": 381, "duration_seconds": null,
             "captured_at": "2026-08-11T23:25:17.359925+00:00",
             "transcript": null, "caption": null, "upload_status": "complete",
             "deleted_at": null, "is_deleted": false}]
}
```

**The viewer consumes:** `id` (routing), `occurred_at` (every rendered date, and the sort),
`created_at` (detail view only, labelled "Logged"), `title`, `body`, `entry_type`,
`unlock_at_age`, `is_deleted`/`deleted_at`, `prompt.body`, `prompt.kind` (colour),
`prompt.theme` (detail facts), `tags[].name`, `tags[].deleted_at`, and per media row
`kind`, `path`, `transcript`, `caption`, `duration_seconds`, `bytes`, `s3_key`,
`captured_at`, `upload_status`, `deleted_at`.

**It ignores** `child_id`, `author_id`, `assignment_id` (the prompt is already inlined),
`updated_at`, `child_age_months`, `tags[].source`, `prompt.cadence`,
`prompt.completion_mode`.

Two observations from the bytes that changed how it was built:

- **`occurred_at` is serialized in UTC.** `2026-04-16T17:30-04:00` comes out
  `2026-04-16T21:30:00+00:00`. A viewer rendering in the reader's own zone puts evening
  entries on the wrong day, which for a childhood archive is a silent, permanent
  falsification. Every date is formatted in `manifest.child.family_timezone`.
- **Media paths are explicit, not derived.** Each row carries its own `path` relative to the
  zip root, and `null` when the bytes were not in S3. The viewer never reconstructs the
  `YYYY/MM` folder layout, so it cannot drift from `_media_path`.

## 2. The manifest already carried a birthdate

`manifest.child.birthdate` and `manifest.child.family_timezone` are both present.
**No API change, no format-version bump. `format_version` stays at 1.** The viewer asserts
on `format` and `format_version` and renders anyway when they surprise it (§ Adversarial).

## 3. The `file://` verification — done, not reasoned about

The export was unzipped to `/tmp/viewer` and `index.html` opened by **file path**
(`file:///tmp/viewer/index.html`) in **Chromium 141.0.7390.37**, driven by Playwright
1.62.0. **43 checks, all passing.** Every network request the page made was logged;
all were `file://`.

| | Result |
|---|---|
| **The timeline renders** | 49 cards in 17 date groups, newest first. First group `11 August 2026 · TUE · 5y 2m` — day number, month, weekday, age chip |
| **A photo loads** | 19 `<img>`, all with `naturalWidth > 0` after scrolling the page. `loading="lazy"` means only the near-viewport ones decode at load, which is why the check scrolls first. `src` is relative (`media/2026/08/6ee3c0fc-….png`) |
| **An audio file plays** | `<audio>` reported `duration: 1.5`, `readyState: 4`, `error: null`; `play()` advanced `currentTime` to `0.497` and it was clicked with the mouse, not only scripted. The transcript renders beneath it |
| **Search returns a result** | `"ceiling fan"` → *5 entries match*, matched **through a media transcript**, with the term `<mark>`ed. A query with no hits renders a sentence, not a blank list |
| **A sealed letter shows as sealed** | 2 of the 3 letters render sealed (unlock 16 and 18; he is 5). Each shows the age it opens at and his age now; neither body is on the card. Clicking opens that one and leaves the other sealed. The third (unlock 3) reads normally with *"This was sealed until 3. It is open now."* |
| **Everything else** | Deleted rows hidden by default, one toggle reveals the 50th marked *Removed*; the `path: null` media row renders metadata and a sentence; `#entry/<id>` works by click, by back button, and **cold from the address bar** |

Screenshots: `/tmp/shots/01-timeline.png`, `02-voice.png`, `03-search.png`, `04-sealed.png`,
`05-sealed-opened.png`, `06-detail.png`, `07-birthdate-forward.png`, `08-file-deleted.png`.

The detail view is where the two dates are proved distinct: the Christmas Eve entry reads
**Happened** Wednesday, December 24, 2025 at 8:00 AM and **Logged** Tuesday, August 11, 2026
at 7:25 PM. It was written as `09:00-04:00`; December in `America/Detroit` is EST, so 8:00 AM
is the correct rendering and the DST offset is being applied per-date rather than per-archive.

## 4. The no-network assertion

`tests/test_export_viewer.py::test_nothing_in_the_viewer_reaches_the_network` greps every
shipped byte — including comments, deliberately — for `http://`, `https://`, and the
protocol-relative `src="//` / `href="//` forms, and prints every offending line.

```
$ uv run pytest tests/test_export_viewer.py -q
21 passed in 3.06s
```

It caught three of its own siblings on the first run: the comment explaining "no `url()`",
the comment explaining "never `innerHTML`", and the comment explaining why
`<script type="module">` is forbidden all tripped the checks that enforce those rules. The
network check still runs against the **verbatim** text — a URL is a tripwire even in a
comment — and the code-shape checks run against a comment-stripped copy.

Six more assertions sit alongside it: no `fetch(`/`XMLHttpRequest`/`importScripts`/
`sendBeacon`; no `type="module"`; no `@font-face`, `@import` or `url()` in the CSS; every
`src`/`href` relative; the three script tags in load order; and a `<noscript>` block that
names `entries.json` and `media`.

## 5. Size delta

On the real 50-entry / 24-media archive:

```
before   59,414 bytes
after    84,060 bytes
delta   +24,646 bytes
```

Compressed, inside the zip:

| File | Raw | In the zip |
|---|---:|---:|
| `index.html` | 2,430 | 1,108 |
| `assets/app.css` | 12,854 | 3,444 |
| `assets/app.js` | 33,077 | 9,634 |
| **the three constant files** | **48,361** | **14,186** |
| `entries.js` | 68,792 | 9,139 |
| `manifest.js` | 1,233 | 679 |

**The three constant files are a flat 14KB compressed on every export, forever.** The
duplicated payload is the part that scales, and it costs 9,139 bytes against
`entries.json`'s 9,106 — a **0.4% premium on the JSON**, because the two files are nearly
identical and deflate almost identically. On an eighteen-year archive dominated by video the
whole readable layer rounds to nothing.

## 6. Least confident, ranked

1. **That `Intl.DateTimeFormat` still knows `America/Detroit` in 2040.** Every date, every
   day group and every age chip goes through the browser's IANA database. Zones get renamed
   and merged; if that one is gone the page catches the `RangeError`, says so in a banner and
   falls back to the reader's own zone — verified with `Mars/Olympus_Mons` — but it falls
   back to *wrong dates with a warning*, which is a worse failure than it looks. The archive
   itself is fine: `entries.json` has the offsets. **This is the single most likely thing to
   quietly rot.**
2. **That the design reads as the same product as the app.** It was built from
   `docs/design-system.md`'s literal values, but that document specifies SwiftUI, and a card
   list in a browser at 44rem is not a phone. The type ramp is approximated with system
   fonts, the mosaic is a simplified four-shape grid rather than the spec's four tile
   layouts, and nobody who knows the app has looked at it.
3. **That hiding soft-deleted *tags* behind the same toggle is right.** Entries and media are
   clearly right. A tag someone removed is arguably just noise, and gating it on the same
   control means the default view silently drops data the file contains. One rule with no
   exceptions was chosen over three judgment calls; it may be the wrong one rule.
4. **That the four-tile cap on a card is the right truncation.** Nine photos and four photos
   produce the same card height and a `+5 more` chip, matching the app. Everything is on the
   detail view. But a page nobody paginates could simply show all nine, and the cap is a
   phone constraint inherited into a place that does not have it.
5. **That `_as_script`'s three byte substitutions are the complete set.** `</` and
   U+2028/U+2029 are the known hazards and both are tested end-to-end through a real browser.
   The reasoning that `<` can only appear inside a JSON string — which is what makes a raw
   `bytes.replace` safe — is sound but is reasoning, not a fuzz test.

## 7. What was **not** verified empirically

- **Only Chromium.** The `file://` check ran in Chromium 141 on Linux and **nowhere else**.
  Safari, Firefox and any WebKit on iOS are unverified. This matters more than usual because
  Safari has historically been the strictest about `file://` local-file access — it is the
  browser most likely to block `media/…` from a page in the same folder, and it is also the
  most likely browser for the person who eventually opens this.
- **Not verified by double-click.** It was opened by file path programmatically. A real
  double-click goes through the OS file association, which is the same URL, but it was not
  literally done by hand on a desktop.
- **Not verified on a real archive.** The archive under test is 50 entries and 24 small media
  objects, seeded through the HTTP API in one sitting. **Nothing was tested at eighteen-year
  scale.** The claim that a linear search over the whole archive is fast enough is reasoning
  from the size of the data, not a measurement — 6,500 entries is perhaps 8MB of JSON and a
  handful of milliseconds per keystroke, but that number was not observed.
- **No real photo, video, or voice recording.** The photos are generated solid-colour PNGs,
  the audio is a generated sine-wave WAV, and **no `<video>` element was ever played** —
  there is no video in the seeded archive. HEIC, which is what an iPhone actually writes, was
  never rendered, and Chromium cannot decode it.
- **The S3 was `moto`, and the Postgres was a local 16 rather than compose.** Docker is
  unavailable in this environment. Neither substitution is on the export code path.
- **No screen reader.** The cards have `role="link"`, a `tabindex` and an `aria-label`
  carrying the date, and Enter opens a focused card — verified. Nothing was heard.
- **Print.** There is a `@media print` block. It has never been printed.

---

## Adversarial re-read — *what breaks if this is opened in fifteen years?*

Every answer that was "a network request", "a build artifact" or "a recent browser API" was
fixed rather than noted. What that turned up:

- **`<script type="module">` would have been fatal.** Modules are fetched under CORS rules a
  `file://` page cannot satisfy. Classic scripts only, and a test enforces it.
- **A card was a `<button>` containing `<audio controls>`.** Interactive content inside a
  button is invalid HTML. Chromium renders it today; in fifteen years it is a play button
  nobody can press. Cards are `<div role="link" tabindex="0">` with the keyboard wired by
  hand.
- **Pressing play also opened the entry.** The delegated click bubbled from the `<audio>` to
  the card. The walk now stops at the first element that owns its own click.
- **Nothing newer than ES2015/2017 is used.** No optional chaining, no `??`, no `Array#at`,
  no `structuredClone`. This costs nothing and removes the question.
- **Everything else degrades rather than fails:** `backdrop-filter`, `-webkit-line-clamp`,
  `loading="lazy"`, `object-fit`, `accent-color` and `<input type="search">` all fall back to
  something legible if unsupported.

### Breaking the assertions on a real unzipped export

30 checks, all passing, each mutating a copy of the archive on disk and reopening it:

| What was broken | What it did |
|---|---|
| **A media file deleted from the folder** | The `<img>` is **replaced** by its metadata and *"listed in the archive, but its file is not in this folder"*. **This was a real defect** — before the fix it left a broken-image icon |
| **Birthdate moved forward to 2025** | The open letter **closed**: 2 sealed → 3, and its body left the card |
| **Birthdate moved back to 2001** | All three opened, bodies present |
| **`format_version: 9`** | Banner naming the version, **and the archive rendered underneath it** |
| **`family_timezone: "Mars/Olympus_Mons"`** | Banner naming the zone and saying it fell back to this computer's, all 49 entries rendered, no errors |
| **Birthdate removed entirely** | All three letters stay sealed — the cautious direction — and no age chips are invented |
| **`entries.js` deleted** | *"This page could not find the archive data"*, and where `entries.json` and `media/` are |
| **A body containing `</script><script>window.PWNED=1;</script>`** | Archive loaded, `window.PWNED === undefined`, and the body rendered as the characters somebody typed |
| **Every entry soft-deleted** | *"This archive has no entries in it"*, and the toggle brings all 50 back |
| **An empty `entries.json`** | A sentence, not a crash |

---

## Not in scope, and deliberately not done

`entries.json`'s contents and shape are untouched. No PDF — it cannot hold a four-year-old's
voice, which is this archive's distinguishing content. No printed book (P4). The viewer is
read-only, permanently: it has no code that writes anything. It is not served from the API.

## One unrelated fix, called out because it is unrelated

`main`'s lint was red on a single recorded `E501` in
`api/alembic/versions/0007_prompt_suppressions.py`, which `docs/roadmap-status.md`
deliberately left unfixed. Wrapping it revealed **five `ruff format` failures hiding behind
it** — the `lint` recipe runs `ruff check` first and a make recipe aborts on its first
failing line, so nobody had seen the format check's output. All six are fixed;
`api/src/rascal/models/prompt.py`, `schemas/prompt.py`, `services/pool_health.py`,
`services/scheduler.py` and `tests/test_entry_tag_source.py` are **whitespace only**
(`ruff format`, no logic). `docs/roadmap-status.md` is corrected.

```
$ make lint
All checks passed!
118 files already formatted

$ make test
467 passed in 87.09s
```

The suite is **446 on `origin/main` and 467 here** — exactly the 21 tests in
`tests/test_export_viewer.py`, both ends counted with `pytest --collect-only` rather than
inferred. The preflight report records 459; that was measured on whichever branch was checked
out at the time (`claude/deploy-readiness-scheduler-5pr0uh`, carrying 13 tests of unmerged
Phase 19/20 work), not on this branch's base. `docs/roadmap-status.md`'s 446 was **accurate**
and is updated to 467; the "265+" it carries elsewhere was never close.
