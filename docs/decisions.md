# RASCAL — Decision Log

Read this before proposing anything. Settled decisions are settled; don't relitigate them without new information.

Last updated: **Aug 9, 2026**

---

## Settled

### Product

| Decision | Rationale |
|---|---|
| One question + one mission per day | Borrowed from Paired. Two items is the most that survives a bad Tuesday. |
| Weekly bigger mission, Saturday | Room for the things that need an afternoon. |
| Monthly measurement mission | Height, weight, same-wall photo. Cheap, and the payoff compounds. |
| Items stack; expire at 14 days | Backlog is fine. Infinite backlog is guilt. |
| Parent can dismiss any item | Not every prompt fits every family. |
| Three completion shapes: did-it, captured-it, wrote-it | The inspiration list is mostly behaviors. A media-required schema loses half the product. |
| Freeform entries are first-class | Not everything worth keeping came from a prompt. |
| No streaks | A parenting app that punishes a missed day is a bad parenting app. |
| Sealed entries with `unlock_at_age` | Letters written *to* him. Impossible to retrofit at 500 entries. |
| Backdating is a core flow, not a setting | Camera-roll backfill is a whole mission category. |
| Kid gets access "later" — mechanism TBD | See open items. |

### Technical

| Decision | Rationale |
|---|---|
| Native iOS first, SwiftUI | Camera roll, mic, background upload, widgets, share sheet. The AI is a bonus; the capture surface is the reason. |
| Web client later, same API | Reserved architecturally, built only if this takes off. |
| FastAPI + Postgres + S3 | What I already know. Fastest path to shipping. |
| Fly/Railway + Neon for the POC | Not Fargate. Migrate when there's a reason. |
| SwiftData as a local cache, server as source of truth | One sync engine, written carefully, once. |
| Server owns the schedule, expiry, all logic | Two phones and a browser must agree on what today is. |
| Sign in with Apple as a credential row, not the identity model | Web signup later requires no migration. |
| Client-generated UUIDs + idempotency keys | Offline creation has to sync cleanly. |
| Presigned direct-to-S3, background `URLSession` | The server never proxies bytes. Video on cellular demands it. |
| Soft deletes and `updated_at` everywhere | The archive should outlive the app. |
| On-device AI output persisted server-side as plain data | A web client will never have an on-device model. The phone is an inference worker. |
| On-device transcription is the priority AI feature | It's what makes his voice findable in 2040. |
| Mission library authored server-side, never on-device | Small model, weak world knowledge, and these prompts are the soul of the product. |
| Rotating refresh tokens in a `refresh_tokens` table | A JWT I can't revoke is a problem the day I lose a phone. This archive has his face and voice in it. |
| Authorization is one FastAPI dependency, not per-handler checks | Retrofitting this at 20 endpoints is how a hole gets left in one of them. |
| Constrained columns are `text` + CHECK, never Postgres enums | Adding a value later is an `ALTER`, not a migration dance. |
| `updated_at` maintained by a database trigger | A bulk `UPDATE` from psql has to move the sync cursor too, or clients silently miss rows. |
| Scheduler takes `as_of_date` as an argument | Testable, backfillable, and re-runnable for a date I slept through. It never reads the clock from inside selection. |
| Keyset pagination on `(occurred_at, id)`, never OFFSET | Backdating inserts into the middle of the order. Offset paging would skip rows. |
| Debug routes and dev-login exist, gated to `local` | Building the daily loop means running it thirty times in an evening. Waiting for 5am is not a development strategy. |
| Prompts seed from a generated `prompts.yaml`, not from the markdown | The markdown stays the authoring surface. Runtime never parses a table. |
| Thumbnails and transcodes deferred out of P0 | `thumb_key` stays null. The capture path has to work before the polish path matters. |
| `entry_type` describes the artifact | In order: attached media wins (its kind); else a `did_it`-mode mission stays `did_it` however much you wrote about it; else any title or body makes it `text`; else `did_it`. Denormalizing the prompt's kind made the Voice filter surface entries with no audio; deriving purely from content pushed noted did-its out of the Did it filter. Both are the same lie in opposite directions. What was asked is still reachable through `assignment_id` → `prompt.kind`. |
| Deleting an entry releases its assignment | "Wrong photo, redo it" happens in week one. A mission stranded `done` with nothing to show for it loses the slot for the day. |
| Letters get their own slot, on the 15th | Sharing `monthly` with the measurement mission meant the money letter could lose that coin flip every month for years. The 15th rather than the 1st because four items in one day breaks the two-item rule. |
| Sync returns a 30-second overlap window; clients upsert by id | `now()` is transaction-start time, so a slow transaction can commit a row already behind another device's cursor and lose it forever. Re-delivery is free — entries are last-write-wins on a client UUID. A sequence has the identical race for a migration's cost. |
| Scheduler runs hourly and filters on local time | One daily cron is 5am in exactly one timezone and drifts an hour against DST twice a year. 24 wakeups a day is nothing, and the job is already idempotent. |
| Video is transcoded to 1080p H.264/AAC in MP4 before upload; the original is written back to the camera roll, never discarded | Same reasoning as HEIC→JPEG: the archive has to open in 2040 in something that isn't Apple, and H.264/MP4 is the most universally decodable video there is. 1080p is what these are actually watched at, and it is roughly a fifth the bytes of 4K — ~70MB/min against ~375MB/min, which over eighteen years and two children is the difference between about 130GB and 650GB. Transcoding is lossy and irreversible, so an in-app capture saves its original to the user's photo library first: the archive stays lean without anything being destroyed to achieve it. |
| `users.is_admin` gates writes to the mission library | `POST /prompts` was authenticated but not authorized. The library is content every child draws from; a grandparent's `viewer` login must not be able to write to it. |
| iOS client lives in this repo under `ios/`, not a separate repo | The client reads `docs/api-contract.md` directly instead of a copy that drifts. CI is scoped by path so the lanes stay independent. |
| Stored `child_age_months` is corrected by explicit user action, never automatically on birthdate edit — a correction is deliberate, not a side effect | `POST /children/{id}/recompute-ages`. Storing the age at write is what stops a birthdate typo silently reshaping 500 entries; the cost is that the typo is otherwise permanent, so the escape hatch has to exist and has to be the user's to pull. It writes only the rows that actually change, because bumping `updated_at` on the whole archive would push eighteen years of entries back through every client's sync cursor to fix three of them. |
| Audio is recorded as AAC in `.m4a`, 44.1 kHz, **mono**, 96 kbps | Same reasoning as JPEG over HEIC and H.264 over HEVC: the archive has to open in 2040 in something that isn't Apple, and AAC in MP4 is the most universally decodable audio there is. Mono because a child talking is a point source and stereo doubles eighteen years of storage for nothing. 96 kbps is transparent for speech and puts a ten-minute recording at roughly 7MB — under the server's multipart threshold, though nothing in the client special-cases audio to stay there: a larger file takes the existing multipart path unchanged. |
| Recording is foreground-only in P0; screen lock stops and preserves | Background audio is a one-line entitlement and a real App Store review surface, and "record two minutes of dinner" is not worth taking that on to close P0. Every interruption path already finalises to a playable file, so adding the entitlement later changes when recording stops, not whether anything is lost. |
| Transcription uses the device's locale, falling back to `en-US` **only** when no model for the device's locale is installed — and the row records which was used | A Spanish model fed English audio does not produce a worse transcript, it produces confident nonsense, and an archive that cannot say which model wrote a line cannot audit one that reads wrong. Falling back to exactly one known locale rather than "whatever happens to be installed" keeps the failure mode to one case instead of an arbitrary one. `Media.transcript_locale` is client-side only; the server schema is untouched. |
| One transcription at a time, process-wide. No parallel inference, ever | It is a battery and thermal cost on a device someone is holding while parenting, and the archive is not waiting on it. Two analyzers running is twice both for no gain a parent would notice. The sweep also does at most one inference per foreground for the same reason — a foreground is not a licence to hold the phone warm. |
| The backlog is transcribed only when asked, never automatically | The archive holds hundreds of pre-feature voice notes. Walking them on first launch is a surprise battery event with no consent behind it. New recordings transcribe automatically because one recording is not a backlog; the two paths are distinguished by a state on the row, not by a heuristic. |
| A locally written transcript is a **pending local change** and the pull leaves it alone, `failed` included | The one exception to server-is-truth already covers an unpushed entry edit. A transcript is the same shape of thing and a worse loss: until it is pushed it exists in exactly one place, so a pull that overwrote it would destroy words that cost a battery to produce, silently. Note the asymmetry with the upload path, where `failed` deliberately stops counting as pending — there the bytes are safe in storage and the server's copy is better; here there is no second copy. |
| Backfilling a recording this phone does not hold **refuses cellular, hotspots, and Low Data Mode** | A backlog run is hundreds of files fetched at once, started by someone who pressed a button about *transcribing*. That is not consent to a few hundred megabytes of cellular data, and the app must not read one button as permission for the other — the same reasoning that keeps the backlog manual for the battery. It affects only rows that came from another device: a recording made here is read from its staged original and never downloaded at all. The cost is that a phone which never sees Wi-Fi cannot backfill those rows; the row says "Waiting for Wi-Fi" rather than implying the recording is lost, and there is deliberately no override toggle. |
| Transcripts are not editable in this phase | Correcting a transcript is a real feature with a real conflict story — two devices editing the same derived field, and a server that is documented never to regenerate it. Shipping an editor without that story is how the "on-device output is durable data" rule quietly becomes "whichever phone typed last". |
| Video audio tracks are **not** transcribed yet | The roadmap asks for them and the asset API can carry them, but nothing in this environment can run a single real transcription to check, and video's only difference is the container `AVAudioFile` has to open. Shipping a second unverifiable input path on top of an unverified first one is the shaky outcome. It is also the expensive one: a backlog video has to be fetched to be read, at ~70MB a minute. Gated on the audio path being verified on a device. |
| Bundle id is `com.travisterry.childarchive` | A bundle id is permanent and the app name is still open, so it is deliberately name-neutral — RASCAL, SMALL FRY, or anything else can ship on top of it. Settled before the Xcode project exists, because changing it afterward means redoing signing and the Sign in with Apple registration for nothing. `APPLE_BUNDLE_ID` must match it: it is the `aud` claim every Apple identity token is verified against. |

### Design

| Decision | Rationale |
|---|---|
| Warm, friendly, polished — Journey and Raven register | Two attempts at an art-directed riso/poster direction were rejected. |
| Terracotta `#C05A2B` primary, periwinkle `#5566D6` secondary | Derived from the reference screenshots, not invented. |
| Cream canvas `#FDFAF4`, navy-charcoal ink `#23253C` | Never pure white, never pure black. |
| Color carries meaning: orange = missions/photos, blue = questions/voice | Not decoration. |
| Timeline is a scannable date-grouped card list with thumbnails | Not a full-bleed story feed. Every reference app does it this way. |
| Completion = circular terracotta checkmark + spring + haptic | Satisfying, quiet, repeatable. No stamp, no confetti. |
| Light mode only for now | Dark mode is P2 at the earliest. |
| Floating pill tab bar with center + FAB | Straight from the references. |
| Destructive and irreversible actions are isolated in a separate bottom card, never adjacent to ordinary edit rows | A divider between two rows says "these belong together"; a gap says "these do not". Recomputing every stored age in an archive is not a neighbour of changing a name, and a mis-tap between the two is not recoverable by tapping again. |

### Rejected — do not revisit

- Risograph, halftone, misregistration, screen-print aesthetics
- Condensed poster type, rotated headlines, type breaking the grid
- Passport-stamp completion, receipt-spike card stacks
- Full-bleed edge-to-edge photo timeline as the primary view
- Electric cobalt as the secondary color
- Rigid two-colors-only discipline
- Streaks, guilt copy, red urgency states

---

## Open

| # | Question | Needed by | Notes |
|---|---|---|---|
| 1 | The name | P1 | RASCAL is a placeholder. Needed for the widget, TestFlight, and the app icon. Alternates: SMALL FRY, SIDEKICK, HOLLER. |
| 2 | Handoff age — 10, 13, 16, or 18? | P4 | This is a *default* for `unlock_at_age`, set per-entry, so it isn't a lock-in. But it changes how you write. |
| 3 | What the handoff actually *is* — an account, an export, a device, a printed set? | P5 | Worth deciding before writing 500 entries addressed to someone. |
| 4 | Mission tone — warm, plain, or dry? | P1 | Set it before authoring 200 more prompts, not during. The seed library leans dry-and-specific; confirm that's right. |
| 6 | Push notification time | P1 | One per day, silenceable. What time actually works? |
| 7 | Second kid — when? | P2 | Model already supports it. UI cost is a switcher plus per-child scheduling. |
| 8 | Does the printed book include did-it entries? | P4 | A page of behaviors with no photos may read beautifully or may read empty. |
| 9 | Full export format | P2 | Folder of files + JSON manifest. Build it before you'd need it. |
| 10 | **Pronouns, and where the child's name appears in prompts** | **Blocked on a `children.pronouns` column** — onboarding shipped Aug 9 and could not close this; there is nowhere to store the answer, and the column is a Lane A change. See `docs/blocked.md`. | The library is written he/him and stays that way for now — see the changelog entry below, this is deliberate, not an oversight. Onboarding is the unlock: once it collects the child's pronouns, prompts should render with the right ones, and the name should appear where it reads warmer than "your child". Two mechanisms, and they are separable — pronoun substitution is a rendering concern, a `{name}` token is a content-format decision with a contract every consumer must honour. Do not let the second block the first. |

---

## Changelog

**Aug 10, 2026** — Moments v2, built against the design export at
`docs/mobile-app-design-moments/`. **The screen was designed for a state it will almost never be
in**, and the phase is mostly about that.

The archive is six days old. "1 year ago" is empty on nearly every date and will be for a year,
and on many dates for years after — so `fallback: "random"` is not the miss case, it is **the
screen**. Five decisions settled with it.

**The redirect wears the hit's clothes.** Same carousel, same section header, same `EntryCard`s.
What differs is one eyebrow ("From the archive" for "1 year ago") and one italic line naming the
day. A miss given its own visual language would be a language the app spoke most days, and every
one of them would read as a fault. The design file says this in its own sheet — "the miss state
never gets its own visual language" — and it is right.

**The carousel is one card per throwback, and a throwback is a year on a hit and a memory on a
miss.** Three years back give three cards, each standing for the band beneath it. The redirect has
only ever one section, so one-card-per-section left a rail holding a single card beside a screen of
five memories. Per-memory on that branch, per-year on the other.

**No date and no age chip on the redirect's header.** The design draws both, with `4y 2m` beside
"Five at random". Five random memories come from five days and five ages; one of each printed over
all of them is wrong four times, permanently, in an archive whose whole claim is that it knows when
things happened. The header prints neither and the section reads fine without them.

**Dates render in the device's locale, not the design file's.** The export writes "Sunday 9
August" throughout; on an `en_US` phone this app renders "Sunday, August 9", as the timeline's day
headers and Entry Detail have since Phase 4. Pinning Moments alone to the export's British order
would have put one order directly above the other on the same screen. What *is* pinned is the day
itself: `CalendarDay` reads the server's `YYYY-MM-DD` at noon UTC and formats it back in UTC, so a
phone at UTC+14 — where that instant is already tomorrow — still prints the day the server computed
in the child's timezone.

**The closing line says only what one response can support.** The design's redirect ends "Come back
tomorrow — 12 August has three", which is a fact about a day the client did not ask about;
`GET /children/{id}/moments` answers for one date. Inventing it was not available and a second
request for a day nobody is looking at was not worth it, so the redirect carries no closing line
and the hit carries one derived from its own sections.

**"The archive is empty" and "I could not reach the server" are different screens.** Found while
hardening this phase, and it predates it: both leave `sections` empty, and the screen branched on
emptiness alone — so a parent holding 755 entries who opened Moments in a tunnel was told "Nothing
to look back on yet. A year from now this screen is where today ends up." A false statement about
someone's archive, caused by a signal drop, on the one screen whose entire job is to say the
archive is worth having. `MomentsModel` now carries `failed` separately from an empty `sections`,
the invitation renders only when the server actually answered, and a failure shows the quiet notice
alone with pull-to-refresh to retry. It has a test and a screenshot.

Two conflicts between the export and `docs/design-system.md`, both resolved toward the design
system and both worth recording. The export hairlines the gradient-wash throwback card at
`#F2DFE4`, which is in no palette; the design system already names the hairline for that wash —
`sealedBorder` — and that is what is used. And the export renders a sealed letter's body as real
text under `filter: blur(3.5px)`. **The shipped card never reads the body at all**, which is
stronger than blurring one: a blur is an obfuscation of bytes that were still delivered to the
device. `EntryCardModel` sets `preview` to nil, drops the tiles and drops the tags when
`unlock_at_age` is set, and Moments now has its own test that a letter surfaced by the random
fallback keeps all of that — the highest-consequence defect this screen could have shipped, since
Moments is the one surface that puts a sealed letter in front of someone who did not navigate to it.

**Aug 10, 2026** — The seal control. The archive can now write the thing it has been able to read
since Phase 4.

`unlock_at_age` has been in the schema, the design system and the mission library the whole time,
and **eight active `letter` prompts have been served against a client that had no way to set it** —
so "write down the story of the day he was born" produced an ordinary entry his son could read the
next morning. Phase 4 built the reader and no phase owned the writer. Four decisions settled with
it.

**Letters only, and nothing else.** The control appears when the assignment's `PromptKind` is
`.letter`. Sealing a photo or a did-it is a different question — it is about hiding something
rather than about addressing it to a future reader — and the answer is not obviously yes. Freeform
entries have no prompt to be a letter, so they do not offer it either.

**Sealed by default, with an obvious way off.** A letter prompt whose entry is readable tomorrow is
not a letter, so the toggle starts on. It is a toggle rather than a fact because a parent who wants
to write one they can read now should be able to, and because the reader has always agreed with
that — `sealedCard` carries an **Open it** button, on the reasoning that a lock the author cannot
pick is a lock on the wrong person.

**The age comes from the prompt, not from a constant.** `GET /today` already carries the prompt's
`default_unlock_age` on the assignment, so the control opens on the age whoever wrote the prompt
intended — 13 for the birth-story letter, 18 for the money one. It falls back to 18 only when the
prompt has no opinion. The stepper offers 10–21 and clamps a prompt default into that range; the
server accepts 0–120 and the library is free to outgrow the stepper, and starting on a value the
control cannot reach would be worse than starting on the nearest one it can.

**Editing the seal on an existing entry is deferred, deliberately.** `PATCH /entries/{id}` supports
it and nothing calls it. The gap is narrow — a seal is set once, at the moment of writing, by the
person writing — and the surface it needs is not obviously the composer's. It is worth doing when
there is a reason beyond completeness.

And the thing that is **not** settled: `POST /entries` cannot hear "do not seal this". It seals a
letter whenever `unlock_at_age` arrives as `None`, and Pydantic gives it `None` for an omitted key
and an explicit `null` alike — so the off switch cannot be expressed on create. The client sends an
explicit null anyway, because that is correct, and `APIClient.createEntry` notices when the server
sealed a row that asked not to be and says it again through `PATCH`. That sits at the write rather
than in the composer because `EntrySync` re-sends offline entries through the same call, and a
letter written on a train would otherwise seal itself hours later. `docs/blocked.md` has the
four-line server fix that deletes the workaround.

**Aug 9, 2026** — Onboarding shipped, and the flow it shipped is not the one that was drawn.

The Claude Design export at `docs/mobile-app-design-onboarding/` deferred the account wall until
after the parent's first entry: name and birthdate, then a motive fork that picked tonight's
prompt, a recorded answer, and only then Sign in with Apple with a "keep going without it" escape.
It is better product instinct than what shipped, and it was **not** built, for reasons that are
structural rather than aesthetic:

- **The client cannot pick the prompt.** Standing rule 1 — the server owns assignment, expiry and
  what day it is. The fork's whole purpose is choosing tonight's mission on device.
- **The anonymous path needs a local-first entry with no `child_id` and no session**, then a way
  to adopt it into an account later. Every write path takes a bearer token and resolves a child.
  That is a phase, not a screen.
- The notification permission screen and the in-onboarding audio capture are both out of scope for
  the iOS lane by name.

So: **auth first, then name → birthdate → timezone → avatar → Today**, wearing the export's visual
language. The deferred-wall version is worth revisiting when there is an anonymous-entry story;
it is recorded here so it is a deferral rather than a thing nobody noticed.

Four decisions settled with it.

**`SessionState` has four cases and no failure case.** `loading`, `signedOut`, `needsChild`,
`ready(child)`. A failure during setup is never a *place* the app is in — it is something that
just happened at the step the parent is already standing on, and the recovery is always "try that
again". Modelling it as a fifth state would mean navigating away from a screen holding typed input
in order to display an error about it. Failures ride alongside as `notice` and `resolveFailed`.

**A revoked Apple credential signs out; an *unknown* one does not.** `getCredentialState` needs
the network, and `.revoked`/`.notFound` are answers while `.unknown` is the absence of one.
Treating the absence as revocation would sign a parent out of their own archive because a train
went into a tunnel. Same reasoning as the offline-launch rule: a token we hold plus a server we
cannot reach is not a signed-out parent, so that launch stays in `loading` with a retry rather
than falling back to a sign-in screen there is no connection to complete.

**The client computes an age exactly once, and never for the archive.** `AgeText` says nothing in
it calculates an age, and that stands — every age *on an entry* is the server's stored
`child_age_months`. But onboarding shows "4 years, 2 months" under the birthdate wheel before the
child exists anywhere, so there is no server answer to render, and the echo catches a mistyped
year far better than validation does. `DraftAge` is that one exception, it is never stored, and it
is named so a future reader can see it was deliberate.

**The duplicate-child guard is a lookup, not an idempotency key.** `POST /children` has no
`Idempotency-Key` the way `POST /entries` does, so a create whose response is lost has still
created a child. The client asks `GET /children` before offering a retry and adopts what it finds.
Worth adding the key server-side eventually; the client-side guard is correct either way and does
not depend on it.

And the thing that did **not** happen: **open item 10 is still open.** Onboarding was supposed to
be the unlock for pronouns and it could not be — `children` has no column to put them in, and that
is a Lane A change. Asking and discarding would be worse than not asking, so it does not ask.
Client copy is neutral, so nothing regressed; the library is still he/him and still waiting. See
`docs/blocked.md`.

**Aug 9, 2026** — On-device transcription shipped, and the sync rule it needed turned out not to
cover it.

`SyncEngine.hasUnpushedChanges(_ media:)` protected a media row by reading its **upload** state —
`staged`, `uploading`, `uploaded` are in flight, everything else is not. A transcribed row is
`complete` by definition: transcription only runs after the upload lands, because
`PATCH /media/{id}/derived` needs a media row the server already knows about. So the newly written
transcript sat on a row the conflict rule considered settled, and a pull carrying the server's
older copy took the `.update` branch and overwrote it. The fix is a first clause on that function
and a `transcript_state` ladder on the row, separate from `upload_state` because the bytes and the
words reach the server by different routes and fail independently.

Two things about that rule are worth stating because they are asymmetric on purpose:

- **`failed` counts as pending for a transcript, and does not for an upload.** A media row past
  its upload cap has its bytes safe in storage and the server's copy is the better of the two. A
  transcript past its push cap exists nowhere but this phone. Dropping the protection at the cap
  would let the next pull erase it.
- **The guard lives in `Media.applyServerSummary`, not only in the sync engine.** All three pull
  paths funnel through that method — `/sync`, `GET /entries`, and `GET /entries/{id}` — and
  `syncPullEnabled` still ships false, so the pull is the path that mostly is *not* running while
  the timeline's refetch is the one that is. Protecting only the engine would have protected the
  quiet path and left the loud one open.

Also settled this session, in the table above: the locale fallback rule and its recording,
no parallel inference, a manual-only backlog, transcripts not editable yet, and video audio tracks
deferred. And one thing worth naming plainly: **no real transcription has been run.**
`SpeechAnalyzer` is iOS 26 and the app deploys to 18.6, `isAvailable` is false on every simulator,
and the model assets are a download no CI runner has. Everything below the protocol seam is
asserted against a stub and everything above it is real. `docs/device-verification-transcription.md`
is where the other half gets checked, and until someone runs it the quality of this on a
four-year-old's speech is unknown rather than good.

**Aug 9, 2026** — Video transcode settled, and Tigris multipart verified before any client code
was written. A 40MB object was uploaded in five presigned parts and fetched back byte-identical,
so the part-splitting contract, the ETag-per-part requirement, and completion all hold on Tigris
rather than being assumed from S3. `chunk_bytes` came back 8388608 and the server planned five
parts, which is the number the client must split at — not a number it may choose.

Transcode: **1080p H.264/AAC in MP4**, with an in-app capture's original written back to the
camera roll. The reasoning is the same one that made photos JPEG rather than HEIC — the archive
must open in 2040 in something that isn't Apple — plus the storage arithmetic, which is not
marginal: ~70MB/min against ~375MB/min for 4K. Discarding an original outright was rejected;
transcoding is irreversible, and a capture taken in-app exists nowhere else unless it is saved.

**Aug 8, 2026** — **The mission library stays he/him for now. This is a decision, not an
oversight, and it will look like a bug to anyone who reads the library's own rules.**

`docs/mission-library.md` rejects any prompt that "assumes a two-parent household, a particular
income, or a particular ability" — and several prompts say *his mom*, which assumes both a
gender and a household shape. That contradiction is real and it is knowingly left in place.

The reason: this is being developed live against one specific child, who is male, and rewriting
113 prompts to neutral pronouns now would make every prompt read slightly less naturally for the
only person currently using the app, in exchange for correctness that no user yet needs.

**What has to happen, and when:** onboarding is the unlock. Once it collects the child's
pronouns, prompts render with the right ones. Beyond that, the child's *name* should appear
where it reads warmer than a pronoun would — the same idea P3's on-device personalization builds
on. Tracked as open item 10.

Two things for whoever picks this up. The mechanisms are **separable**: pronoun substitution is a
rendering concern needing no new content format, while a `{name}` token is a content-format
decision with a contract every consumer — client, the browser client reserved for 2027, export —
has to honour or prompts render with literal braces. Do not let the second hold up the first.
And prompts naming a *specific other parent* ("his mom") need rewriting or cutting either way;
that is the household-shape assumption, and it is the part the library's own rules already
forbid.

**Aug 9, 2026** — The client's half of sync lands, and **ships switched off**. `GET /sync` is
now read, applied, and gated behind `syncPullEnabled`, which defaults to false. The engine
touches the local cache every other screen reads from, so it is verified against a real archive
before it is trusted with one; a dry-run mode does a genuine `GET /sync`, computes exactly what
it would insert, update and soft-delete, and reports it without applying a single change. Four
decisions settled with it.

**The conflict rule.** Last-write-wins by `updated_at`, matching the server — *except* that a
local record with unpushed changes is never overwritten. The push queue wins, and the record
reconciles on the next pull after a successful push. This is not a refinement of last-write-wins,
it is the thing that makes the engine safe: a row this phone has written and not yet sent is the
parent's most recent intent, and the server's copy is by definition older. Without it, an edit
made on a train disappears the moment the train reaches a signal. The same rule covers media
still uploading and — the case Today already relied on — an assignment completed here that the
server still calls pending. A pull must never revert a locally-completed mission, and that is now
enforced in the cache rather than only papered over by the board's merge.

**The overlap window is handled by being idempotent, not by deduplicating.** The server hands
back `max(updated_at)` minus thirty seconds so a row written by a slow transaction is
re-delivered rather than skipped. The consequence for the client is not that duplicates are
tolerable — it is that **every apply path must leave the store byte-identical when run twice**,
because the window guarantees it happens on every pull. Every apply is therefore a pure
assignment of server fields and never an accumulation, and the idempotency is asserted directly
rather than assumed. Two other things fell out of reading the server rather than the contract:
`GET /sync` does not page, and an *empty* batch still returns an advancing cursor (`now() - 30s`,
since there is no maximum to take), so the round loop terminates on an empty batch first and on a
non-advancing cursor second. Testing only for cursor movement spins forever against an idle
archive.

**The trigger set is deliberately boring:** app foreground, pull-to-refresh on Timeline, straight
after a push-queue drain, and Today's load. **Background sync is deferred** — no `BGAppRefreshTask`,
no timers. It is a separate decision with battery and App Review implications, and taking it
alongside a first sync engine would mean shipping two unverified things and being unable to tell
which one misbehaved. The four triggers coalesce: overlapping ones join the in-flight pull rather
than queueing four identical ones. Push always drains before a pull applies, for the same reason
entries drain before media in the upload sweep — pulling first can hand back a stale row that
overwrites a local edit still in the queue.

**`Assignment` becomes a local `@Model`**, which is the one part of this that touches the
SwiftData schema. It was taken rather than dropping the `assignments` array on the floor: a new
entity is the only schema change that cannot fail lightweight migration the way rule 6 of
`ios/CLAUDE.md` describes, because there are no existing rows of a type that never existed. It is
covered by a real old-schema-to-new-schema test — a store written by the previous three-entity
schema, reopened under the four-entity one — which is the test `StoreMigrationTests` said it could
not write until there was a previous schema to express.

**Aug 8, 2026** — Completion motion widened after the first device session; the no-confetti and
no-streak rules **reaffirmed, not relaxed**. On a phone the completion check simply appeared,
which read as a status field changing value rather than as finishing something. The fix is
motion and timing, not decoration: the check now *draws itself* on the existing spring
(`response: 0.35, damping: 0.7`), the upload ring completes into it so saving and finishing are
one gesture rather than two states swapped at the end, the card settles into Done Today over
0.4s, and the haptic warms from `.light` impact to `.success` notification. Explicitly still
excluded: confetti, particles, stamps, sound, streaks. The original rule was never meant to mean
flat — it meant nothing that congratulates compliance. Reduce Motion still fills the check
without springing, because removing the feedback entirely is a different bug.

Same session: Today now merges local state over the server's board. A photo mission completed
offline kept rendering as not-done while a text answer on the same screen showed done, because
one had synced and the other had not — the same action producing two outcomes decided by network
timing. A completion is a fact about the parent's evening; whether the server has heard is a
fact about the network, and the screen must not conflate them.

**Aug 8, 2026** — Bundle id settled as `com.travisterry.childarchive`, ahead of the Xcode
project rather than after it. Name-neutral on purpose: open question #1 is still open, and a
bundle id outlives whatever the app ends up being called. This closes the "what I need" line
in `blocked.md` §1 — enrollment can now proceed against a real identifier, and
`APPLE_BUNDLE_ID` has already been flipped from `com.example.rascal` to match it, in
`.env.example` and in `ci.yml`; the Fly secret follows when the app exists.

**Aug 8, 2026** — The iOS client lives here, under `ios/`, rather than in its own repo. It
was planned as a separate one; the deciding argument is that a client in the same tree reads
`docs/api-contract.md` directly instead of a copy that drifts, and `make fixtures` can
capture real API responses into `ios/Fixtures/` as ground truth for JSON decoding. The cost
is that CI had to learn the difference: `ci.yml` and `deploy.yml` now carry path filters so
an iOS-only commit neither runs the Python suite nor deploys an unchanged API. The two lanes
are kept apart by convention rather than by tooling — `CLAUDE.md` and the new `ios/CLAUDE.md`
each state that an agent in one lane never edits the other. No API behavior changed.

**Aug 4, 2026** — Hardening pass before iOS. Six decisions settled above, of which three
change the schema: `entry_type` narrows to the five things the derivation can produce,
`letter` joins the `slot` CHECK, and `users.is_admin` arrives. Migrations `0002` and `0003`,
both reversible, both taken while the database is empty. Two correctness fixes with no
schema cost: deleting an entry releases its assignment, and the sync cursor carries a
30-second overlap window. The coverage table in `mission-library.md` was corrected — it had
under-counted video, activity, and weekly since before the last prompts were added.

**Aug 3, 2026** — Build started. Sprint One planning added an "Epic Z" of ground-zero
infrastructure the original backlog assumed but never defined: repo skeleton, migrations,
seed loader, deploy pipeline, S3 setup. Backend build order fixed at skeleton → schema →
seeds → auth → endpoints → scheduler → deploy artifacts, with iOS deliberately held back
as a separate task so the first agentic run needs nothing from me. Nine technical
decisions settled above, of which two change the data model: a `refresh_tokens` table and
CHECK constraints in place of Postgres enums. Thumbnail generation cut from P0.

**Jul 31, 2026** — Design direction reset after two rejected mockup rounds. Riso/poster out, Journey/Raven register in. Palette rederived from reference screenshots. Timeline changed from full-bleed story feed to date-grouped card list.

**Jul 30, 2026** — Pivoted from web-first to native iOS first. Backend constraints for a later web client fixed at the same time. On-device AI plan set: transcription first, structured extraction second, camera-roll backfill third.

**Jul 30, 2026** — Initial scope set. Six phases, P0 exit test defined as behavioral (seven days of unforced use) rather than a feature checklist. Year One printed book set as the December forcing function.
