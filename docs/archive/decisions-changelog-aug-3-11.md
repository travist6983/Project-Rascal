# RASCAL — decision changelog, Aug 3–11, 2026 (archived)

**Archived Aug 25, 2026 by phase 123.** The Changelog in `docs/decisions.md` had reached **79 KB —
a third of that file** — and the oldest two-thirds of it describes the build's first nine days.
Those entries are moved here **whole and unedited**; `decisions.md` keeps every *settled decision*
and every *open item* in full, plus the Changelog from **Aug 19, 2026 (phase 95) onward**.

**What a Changelog entry is, and why moving it is safe.** It records *when a decision changed and
what argument moved it*. The decision itself lives in the Settled table above, which did not move
and is not summarised — so the answer to *what is the rule* is unchanged in the live file, and only
the answer to *what was the rule in the first week* is here.

* * *

The item had been split into a collection half and a rendering half with an instruction not to
let the second block the first. Both are answered, and the second turned out to be the one worth
thinking about, because it is a contract every consumer has to honour for eighteen years.

**The collection half was never a design problem, it was a stale blocker.** `children.pronouns`
landed in Lane A before Aug 11 and nothing has written to it since; the item read "blocked on a
column" for two days after the column existed. Onboarding asks after birthdate, Settings offers
the same choice, and skipping stores `null` and finishes setup.

**The rendering half turned on one linguistic fact.** They/them is the only English pronoun set
whose five grammatical slots are five distinct words, which makes it the only set usable as a
key. A he-keyed table looks natural and matches the existing library, and it is wrong: `{his}`
cannot be resolved because English uses one word for "his favourite" and "that one is his" where
they/them uses "their" and "theirs". The bug would have been invisible until the first she/her
child, which for this project means invisible until well after the format was permanent.

**Verb agreement is the part that will look like over-engineering and is not.** Four compound
tokens — `{they_are}`, `{they_were}`, `{they_have}`, `{they_do}` — instead of inflecting the
word after a pronoun. The argument is not that conjugation is hard; it is that a conjugator
fails *silently*, and a permanent archive cannot hold text that is usually grammatical.

**Nothing migrates, and that is the design's whole purpose.** The renderer passes tokenless text
through byte-identical, so the 113 seeded prompts render as they do today, forever. Tokenised
and literal prompts coexist with no reconciliation, no rewrite, and nothing for
`test_seeding.py`'s coverage table to disagree with. The decision binds the ~~**79 unreviewed
candidates**~~ **139 unreviewed candidates as of Aug 22, 2026** — the Aug 4 sweep's 79, plus 60 from
a second sweep that targeted the themes that had since become the thin ones — and every batch after
them. Those 79 are not being edited in this phase, since they are awaiting a human read that has not
happened and rewriting them here would consume that review without anyone having done it.

**The client work has no phase number, and that is deliberate.** This was drafted against
"phase 20", which has since shipped as something else — the nine TestFlight defects, PR #47,
which explicitly held pronouns out of scope while editing `ChildSetupFlow.swift` for other
reasons. Rather than mint a number that a third phase can collide with, the work is tracked by
this item and by `docs/blocked.md`'s Onboarding section until something claims it.

**Aug 11, 2026** — **Three more open items answered, and together they decide what the archive
*is* rather than how it is built.** Items 2, 3 and 9 are now settled rows above.

**The handoff question was two questions and answering them separately dissolved most of it.**
Item 2 asked for a handoff *age* and item 3 asked what a handoff *is*, and the confusion between
them is why both sat open since the roadmap was written. `unlock_at_age` is a per-entry letter
seal — it is already per-prompt, already varies 13 and 18, and does not want a global default.
The handoff is a separate thing entirely: an access event, decided by the family, with a 13
floor that comes from COPPA and Apple ID rules rather than from a product opinion. Neither
answer requires code in P0 or P1.

**The shape of the handoff is worth not relitigating later: shared access, not transfer.** The
child becomes a second user against the same archive and the parent keeps theirs, so "we keep
using it together" is the default rather than a feature. The schema already supports this —
`users` is separate from `credentials`, and the guardians route exists as a P2 stub — so the
decision costs nothing today and would have been expensive to get wrong.

**One column is deliberately not being added.** The obvious follow-on is whether some entries
stay hidden after the handoff, and the answer is that `unlock_at_age` already covers it: unsealed
is visible on access, sealed is visible at its age. A third "visible to child" state would mean
writing entries into his archive that are being withheld from him, which is a different product.
Recorded because a column not added is invisible in the schema and a future reader will wonder
whether it was considered.

**The export answer is a correction to a framing rather than a new format.** The zip that exists
is right and is not changing. What was missing is that it has been serving two audiences with
one artifact: machines, which want `entries.json`, and a thirteen-year-old, who does not. So the
archive is three layers — backup, readable, printed — and the readable one is a static site
added to the same zip, derived from the same data, with no second export path.

**PDF was considered and rejected on a technical ground rather than a stylistic one.** It cannot
hold audio or video. The distinguishing content of this archive is a four-year-old's recorded
voice, and a handoff format that silently drops it is not a copy of the archive — the same
reasoning that put did-it entries into the printed book under item 8. PDF remains available as a
derived artifact.

**The viewer's constraints are all about 2040 and none of them are negotiable.** No build step,
no network, no framework, relative paths, system fonts, vanilla JS. The one that will look like
an odd implementation detail and is actually the load-bearing constraint: **browsers block
`fetch()` from a `file://` origin**, so a double-clicked `index.html` cannot read `entries.json`
sitting beside it. Hence `entries.js`, the same bytes with a variable assignment around them,
loaded by a `<script>` tag. That single fact decides the file layout, and discovering it in 2040
instead of now would mean discovering it with nobody left to fix it.

**Aug 11, 2026** — **Four open items answered by the owner, and one unblocked.** Items 4, 6, 7 and
8 are now settled rows above and struck through in the Open table. The two that change future work
are worth stating plainly, because neither is a no-op and neither is retroactive.

**Mission tone is warm and cheerful (item 4), and the library it was measured against is not.** The
item's own note said the seed library "leans dry-and-specific; confirm that's right" — and the
answer is that it is half right. The specificity is the thing that makes a prompt work and it
stays; the dryness was never chosen. **The 113 seeded prompts are not being rewritten**, for the
same reason the he/him decision holds: a bulk rewrite of the library is a large, risky, low-value
edit to content that is already serving, and `test_seeding.py` asserts a coverage table that a
sweeping edit would have to be reconciled with by hand. The decision binds what is authored next.

**That makes the ~~79~~ unreviewed candidates the first thing this decision touches.** They were
generated with `docs/mission-library.md` as the style reference — that is, against the dry
library — so they inherit the tone that was just changed, and they are sitting in
`docs/prompt-candidates/` waiting on a human read that has not happened. **The count is 139 as of
Aug 22, 2026**, and the tone argument in this paragraph applies to the Aug 4 seventy-nine only: the
Aug 22 sixty were generated against the current library *after* this decision settled, so they are
the first batch this row describes rather than the last batch it indicts. Read them for warmth as
well as for accuracy. `scripts/generate_prompts.py` reads the library as its style reference on
every run, so the tone of future batches will drift toward whatever the library actually contains:
the warm prompts have to get *into* it before generation compounds the old voice.

**The printed book includes did-it entries (item 8)**, which is rule 4 of the standing rules
reaching P4 intact. The recorded worry — that a page of behaviours with no photos may read empty —
is answered as a layout constraint rather than an inclusion question: they are set as text with
their date and the prompt they answered, not as photo pages missing a photo.

**Item 6 closed as "what shipped is the answer"** — one a day, `notification_time` on the user,
19:00 default, every user free to move it. **Item 7 closed as scheduling rather than design**: the
schema and the Today v2 switcher already carry a second child, so P2 pays the remaining cost when
P2 starts and nothing in P0 or P1 should build toward it.

**A letter can be written on any day** — decided the same evening, and it came out of reading this
file rather than the app. "The sealed letter, whole" in `docs/roadmap-status.md` described a
finished feature and never said where the control appears, so the section read as *shipped* while
the app read as *there is no way to write a letter*. Both were true: it is offered only from a
`letter` assignment, and the scheduler creates one only on the 15th. The scheduling decision is
sound and stands; what was never decided is that **writing** one has to wait for it. It does not.
Design is being done in Claude Design, nothing is built, and the API needs no change. The
roadmap file's own omission is recorded there as the defect it was.

**Item 10 is no longer blocked**, which is a correction rather than a decision. It has read
"blocked on a `children.pronouns` column" since onboarding shipped on Aug 9; the column exists, and
so do `POST /children/{id}/avatar-upload-url` and its read-back route, `EntryOut.prompt_body`,
`?sealed=` and the tag `source` that gated Phase 17. Lane A built all of them and nothing marked
them resolved. The remaining half of item 10 is iOS: onboarding still does not ask for pronouns.
See `docs/blocked.md`, which was corrected in the same pass.

**Aug 10, 2026** — Settings v2, built against the design export at
`docs/mobile-app-design-settings/`. The last screen still wearing its PR #21 scaffolding, and the
phase is mostly about which of the design's claims the app can actually make.

**Settings opens on the child.** `ChildHeroCard` replaces the `Name` row with a terracotta avatar
disc, the name, the age and the born date, and it opens the same sheet the `Birthday` and
`Timezone` rows do — so the sheet kept all three of its entry points and one row left the list.
Section labels now run a hairline out to the trailing edge, which is what stops nine stacked cards
from reading as one column.

**Phase 20 — the sync card's own numbers were audited against that same rule, and one row was
rewritten rather than dropped.** "Last pull — Off" was a placeholder: a row whose value is a
timestamp rendering the *feature's* on/off state. It now shows a real relative time, "Never", or
"Never — pulling is off" when pulling is disabled and a pull therefore cannot have happened.
Nothing was dropped for want of a number, because every value on that card traces to the local
store: the pending count and the transcribe backlog are `FetchDescriptor`s over `Media`, and the
pull rows read the engine's own state. **The pending count did have to be split**: it folded media
past the retry cap in with media still on its way, under a line promising they would "finish on
their own" — which a `failed` row does not do. Waiting and stalled are two sentences now. No
`GET /children/{id}/stats` was invented, and nothing on the card claims a number the client cannot
see.

**The floating tab bar's `+` was drawn inside the capsule it is meant to sit above.** It was the
middle child of the `HStack` carrying the capsule's `.background` and `.overlay`, and an overlay
composites above everything it modifies — so the bar's own `border` stroke drew across the top of
the disc, which is the faint pale ring in the TestFlight screenshot. The disc is now composited
after the capsule, lifted clear, and ringed in `canvas` deliberately. Its shadow is the design
system's `y: 2, blur: 8, opacity: 0.04` rather than the terracotta glow it carried, which was not
a token. The bar now reports its measured height so the scrolling screens behind it inset by what
is actually there instead of a hardcoded 84.

**Three of the design's elements need numbers the API does not serve, and were dropped rather than
faked**: the hero's `412 entries · 1,204 photos · 3 sealed` strip, the `First entry` row, and the
sync card's progress bar. The local cache is paged and partial by construction, so counting it
answers "how much of the archive has this phone paged in" — and `design-system.md` already settles,
for `TimelineHeader`, that the client never claims to know the size of the archive. A
`GET /children/{id}/stats` would restore all three; that is an API-lane conversation, not a patch.

**`Recompute ages` was refused a seat in the design's `Advanced` group.** It rewrites
`child_age_months` across the whole archive, and it keeps its own card, its own label, and its own
whitespace. A divider between two rows says these belong together; a gap says they do not. The rest
of the grouping was adopted verbatim — the dry run and the reset moved out of the tail of the sync
card into an `Advanced` card of their own, which is a genuine improvement on where they were.

> **Amended in Phase 20 — both halves of that paragraph moved, and the rule above did not.**
>
> **Recompute is now a checkbox on the child-edit sheet, not a `Corrections` card in Settings.**
> It appears *only* while the birthdate differs from its loaded value, disappears if it is changed
> back, and defaults to unchecked. On Save: `PATCH /children/{id}` first, and
> `POST /children/{id}/recompute-ages` **only if that succeeded and the box is ticked**;
> `entries_updated` is then shown, because that number is the confirmation the thing happened. A
> recompute failure does not roll back the birthdate — they are two outcomes and the parent is told
> both, with the birthday reported as saved.
>
> **A future reader finding recompute on the edit sheet must not conclude the rule was abandoned.**
> The settled rule is the row at the top of this file: *stored `child_age_months` is corrected by
> explicit user action, never automatically on birthdate edit — a correction is deliberate, not a
> side effect.* A box that defaults to unchecked and must be deliberately ticked **is** explicit
> user action. What the rule forbids is recomputing *because* the date moved, and nothing does
> that. `EditChildModel.recomputeAges` conjoins `birthdateChanged` in its **getter**, so the flag
> cannot outlive the condition that offered it.
>
> What changed is only the placement, and the reasoning for the original placement was about
> *adjacency to ordinary edit rows in a list of unrelated settings*. On the sheet the parent opened
> to fix the birthday, the correction is not a neighbour of an unrelated row — it is the second
> half of the thing they came to do.
>
> **The `Advanced` card is gone too.** The dry run and the reset now sit behind one
> `Sync diagnostics` row inside the Syncing card. Neither action was deleted and their copy is
> unchanged: the dry run is what gets read before the pull flag is flipped, and that is still
> ahead. A top-level card put two diagnostics for an engine that ships behind a flag, and has
> never met a real archive, at the same level as the archive and the account.

**The gradient behind the hero lost on contrast before it lost on principle.** The palette's
`Gradients.wash` is reserved for emotional beats, and whether the child card counts as one is a
real argument — but `inkMuted` over that gradient measures 4.22:1 on its middle stop, under AA, so
the question never had to be settled. The hero is `terracottaSoft`, which is the design's own first
gradient stop to the digit and measures 4.69:1.

**The design's own `tokens/colors.css` agreed with `Palette.swift` exactly, for the third phase
running.** Eleven values hardcoded in the prototype appear in neither. All eleven snapped to
existing tokens; no `Palette` constant was added. **Paper grain was dropped for the third time and
deliberately not resolved** — it remains a three-way disagreement between the bundle,
`design-system.md`, and two decisions files that do not mention it.

**One latent defect, found by running the app rather than reading it.** `SyncStatusModel` was built
in `.task`, which runs once, and `RootView` builds the `SyncEngine` in *its* `.task` — so a render
that reached Settings first left the engine nil and the model was never retried. The dry run, the
reset, the pull toggle and the position rows were then absent for the life of the session with
nothing on screen saying so. Pre-existing since PR #21; the redesign made it worse by turning those
rows into a whole labelled card that simply was not there. Now rebuilt on
`.onChange(of: syncEngine != nil, initial: true)`.

**Aug 10, 2026** — The share sheet. A photo goes from Photos into an entry without opening the app,
and the phase is mostly about a date rather than about a screen.

**The extension stages; the app drains.** The extension copies the bytes into the App Group
container the widget already opened, writes a versioned record, and exits. The app turns that into
an `Entry` and its `Media` rows on the next launch or foreground, through `ImagePipeline`,
`VideoPipeline`, `StagingStore` and the existing sweep. Three reasons, and each would have been
enough on its own: a share extension runs under a hard memory ceiling and a 4K minute is ~250MB, so
a transcode or an upload there is a crash waiting for a large file; a token refresh inside an
extension can invalidate the app's own session, which is the reason the widget has no network
either; and media may not upload until the server has acknowledged its entry, so an extension
uploading on its own would break an ordering the whole sync design rests on and produce 404s.

**`occurred_at` comes off the file, and the fallback says so.** This is the part that needed the
most care and it is the part with no second chance. A photo shared from the camera roll is usually
not from today, and defaulting to now would file a 2019 photo under this week — an error that
produces an entry which looks completely normal, is on the wrong day, and stays there. So the date
is read through the app's own `ImagePipeline.exifDate`, the **earliest** capture date wins on a
multi-select, and `now` is used only when nothing carried a date at all. Which of the two happened
is stored on the record, so the screen can say *"This photo doesn't say when it was taken, so today
is standing in"* rather than presenting a guess as a fact. `MediaDraftBuilder.suggestedOccurredAt`
now calls the same function, so the composer's rule and the share sheet's are one rule rather than
two that agree today.

The date is **shown and not editable**, which is a deliberate narrowing rather than an oversight. A
graphical picker is most of a share sheet, the entry is editable in the app the moment the drain
files it, and what this screen owes a parent is the chance to *notice*. Whether that is enough is
§10 of the device checklist.

**Idempotent by construction, and reaping is ordered behind the server.** The entry's UUID is
client-generated in the extension and written into the record, so a second drain finds the row and
writes nothing — no heuristic, no timestamp comparison. Ingest runs before the sync sweep and reap
runs after it, because staged bytes may only be removed once `existsOnServer` is true. Reaping any
earlier would mean a failed `POST /entries` had already thrown away the only copy of a photo, which
does not exist anywhere else once Photos is closed.

**No deduplication across shares**, recorded in the table above as a decision. It is the one thing
in the phase that was specified as optional and it was left out rather than approximated.

**Light mode holds here.** The widget's dark palette was an exception granted because a widget
cannot opt out of the system appearance; a share extension can, so it does. The exception stays
scoped to the widget.

One thing worth recording about how this was checked, because it changed a test rather than a
design: the memory assertion — the one thing a simulator genuinely cannot answer — was written as a
before-and-after footprint reading, and **it passed a mutation it should have caught.**
`Data(contentsOf:)` maps a file of that size and mapped pages are not charged to `phys_footprint`.
It samples a peak on a second thread now, and reports 316MB against a 40MB ceiling when the copy is
replaced with a read into memory. The mmap limit is written into the test. The real ceiling still
cannot be measured anywhere but on a phone, and `docs/Device-Verification/device-verification-share-extension.md` §3
asks for the number.

**Aug 10, 2026** — The Home Screen and Lock Screen widget. Four decisions, one of which is an
explicit exception to a settled rule.

**The widget reads a snapshot; it never calls the API.** The app writes a small versioned file
into a shared App Group container whenever the Today board changes, and the extension renders
whatever is there. This is not a shortcut taken to save work — an extension refreshing a rotating
token concurrently with the app can invalidate the app's own session, and the resulting logout
happens rarely and is very hard to attribute. The extension is given no networking, no keychain
access group, and nothing to refresh.

The cost is staleness, and staleness is handled rather than tolerated. A snapshot whose day is
not today — computed in the child's `family_timezone`, never the device's and never UTC — renders
a neutral state. The state a stale snapshot resolves to carries only the child's first name, so
yesterday's mission is not merely undrawn, it is unreachable. Showing nothing is correct; showing
the wrong day is a defect, and this makes the defect structurally impossible rather than a rule a
view has to remember.

This is the one place a client asks what day it is, and it is worth being precise about why that
is not a violation of "the server owns the schedule": the computation can only *withhold*. It
cannot assign a prompt, extend one, or invent a day. Getting it wrong shows a parent less than
they should see. Not doing it at all shows them the wrong day.

**Dark mode for the widget, and only the widget.** "Light mode only for now" is settled and stays
settled for the app; a widget has no way to honour it. `WidgetPalette` adds a warm dark rendering
that keeps both rules the design system actually cares about: never pure black and never pure
white, so the ground is a charcoal drawn *down* from the cream canvas rather than up from `#000`
and the ink is a warm off-white; and colour still carries meaning, so terracotta and periwinkle
are lifted in luminance rather than replaced. Inverting to black-and-white was the obvious move
and it reads as a different product. **This does not open dark mode for the app.**

**The Lock Screen has no colour at all**, which is a harder version of the same problem: accessory
families render as a monochrome mask, so the terracotta/periwinkle distinction that carries
meaning everywhere else conveys nothing. It is replaced by the SF Symbol each prompt kind already
carries on its `PromptCard` — a walking figure, a camera, a speech bubble — plus weight and size
hierarchy. The Lock Screen therefore inherits the app's existing vocabulary instead of inventing a
second one, and `accessoryCircular`, which has room for exactly one glyph, is still able to say
which *kind* of thing is waiting.

**No counts on the widget, as a product rule.** No backlog number, no streak, no ring, no
percentage, in any family. The tone rules already forbid these everywhere; the widget is where
they matter most, because a Home Screen is the one surface a parent cannot choose not to open.
`waiting` — the backlog of previous days — is deliberately never consulted when the snapshot is
built, so there is nothing to count even by accident. `accessoryInline` says "Mission waiting",
never "2 waiting".

**Aug 11, 2026** — iOS Phase 17 landed structured extraction over entry bodies.

**Extraction runs once per entry, and never again.** The phase offered a choice: track every
`device_ai` tag a parent deleted so a re-run could not resurrect it, or do not offer re-running.
Not re-running makes the failure *impossible* rather than defended against — there is no tombstone
list to get wrong, and a tag the parent removed is gone for good. The cost, accepted knowingly: an
entry whose body is edited afterwards keeps the tags it got the first time. **Two tests named in
the phase file are retired by this** — "re-running replaces `device_ai` tags" and "a hand-deleted
tag does not return on re-run" — replaced by one stronger assertion: extraction never runs twice.

**A sealed entry is never read, and the guard sits before anything touches the body.** A sealed
letter is written to be opened years from now; its contents leaking into tags that render on
today's timeline would show the parent the exact thing they deliberately locked. Asserted both by
outcome and by the model never being handed the text.

**The parent's words are never touched.** Extraction writes tags and nothing else — `title` and
`body` are not in the payload at all, not even as unchanged values.

**Scoped to entry bodies, not transcripts**, deliberately: extraction over text needs no
transcriber, so this phase is not gated on the device checklist and does not stack two unknowns in
one branch. Transcript extraction is a small follow-on once transcription has been verified.

The model is reached through `EntryExtracting`, so a hard task could later be routed elsewhere
without touching a call site. `@Generable` and `LanguageModelSession` are confined to one file
behind `@available(iOS 26, *)`.

**Aug 11, 2026** — Push notifications, server side. One a day, and the day it stays quiet.

Built against a **stubbed APNs client**, the way transcription was built against a stubbed
transcriber. No APNs key exists — it comes from the same Apple Developer trip as the Sign in
with Apple key, and `docs/blocked.md` §1 is still open — so **no real notification has been
sent from this repository and none of Apple's behaviour is verified**. What is verified is
everything on this side of the socket, which is where all of the product decisions live.

**The durability problem is the whole shape of this phase.** Phase 12 demoted the scheduler
to an optimisation by making `GET /today` fill the day on read: a machine that slept through
5am costs milliseconds, not a lost day. **That repair does not exist for a notification.**
Nothing calls anything at 19:00 on the user's behalf, so a send window nobody looked at is a
notification that simply never happened, and it is experienced as the feature not working.
So the job is catch-up capable instead — every run sends anything whose window passed today
and has not been sent — and the staleness tolerance is what stops catch-up from becoming a
2am notification, or a day-long outage waking every user at once when it recovers.

Phase 12's actual answer for scheduler durability was `min_machines_running = 1` plus the
read path, and it is **not sufficient for push**. It keeps the machine serving the read path
awake; it does nothing about the scheduled machine, which `fly deploy` neither creates nor
updates. For assignments that is fine — the read repairs them. For notifications the
scheduled machine *is* the mechanism, so a fresh app with nobody to run `fly machine run` by
hand sends nothing, forever, with a green health check. Recorded in the runbook §4b and in
`blocked.md` in those words, because it is the one thing about this feature most likely to
be discovered a month late.

Two things the send job deliberately does not do. It does not send when every item for today
is done — no "great job", no summary, no streak, because a congratulation is still an
interruption and a parent who finished should not be pinged about finishing. And it never
puts entry content, sealed content, or a count of waiting items on the wire: the message type
has no field that could carry them, so a future edit cannot leak one by accident.

The tolerance is **two hours**, and it is a consequence of Fly rather than of taste. Fly's
finest schedule is hourly, so a window is already up to an hour old before any run looks at
it; two hours absorbs exactly one entirely missed run while still never reaching the middle
of the night from a daytime window. The default time is **19:00** and open item 6 stays open.

One migration hazard found and fixed on the way, unrelated to push but blocking it: migration
`0001` imported `TABLES_WITH_UPDATED_AT` from `rascal.models.base` and looped over it. That
list is the *current* model layer, so the moment any later migration added a table with an
`updated_at`, `0001` would have tried to attach a trigger to a table three revisions away
from existing — and `alembic upgrade head` from empty would have failed. It is now a literal
frozen at that revision, and later migrations attach their own.

**Aug 10, 2026** — Deploy readiness, and the scheduler stops being load-bearing.

The brief for this work assumed assignment creation ran in-process on APScheduler and would
die when Fly stopped the machine. **It does not, and never did** — there is no APScheduler
anywhere in the repo; the job is `python -m rascal.jobs.scheduler` on a Fly scheduled
machine, and `min_machines_running = 1` was already set. The real fragility was one step
further out and the fix is the same one: a scheduled machine is invisible to `fly deploy`,
so nothing fails if it is never created, and the machine that is created pins its image and
can run months-old code. `GET /today` now fills the day itself, which makes all of that an
optimisation rather than a dependency.

Two configuration defects found on the way, both of which would have produced a deployment
that boots green and cannot accept a single upload: `fly.toml` set `S3_REGION = "us-east-2"`
against a Tigris bucket, and nothing anywhere set `S3_ENDPOINT_URL`, whose unset meaning is
real AWS. `docs/DEPLOY.md` §5 was instructing both. `scripts/verify_deployment.py` was then
run against a real `ENVIRONMENT=prod` process and **caught the endpoint one from the
outside**, which is the only reason to believe the script is worth having.

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
asserted against a stub and everything above it is real. `docs/Device-Verification/device-verification-transcription.md`
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

**Aug 10, 2026** — Phase 18 built the camera-roll backfill engine. Four decisions.

**A backfill is not an assignment, and the rule is structural rather than remembered.** The server
owns the schedule; a suggestion built from this phone's camera roll is something the server cannot
know about. `BackfillEntryPlan` therefore has **no field that can hold an assignment**, and the
composer request it builds passes `assignment: nil` as a literal. Entries carry `assignment_id`
null — freeform entries are first-class and this is what that is for.

**`occurred_at` comes from the asset, and the fallback is the month being backfilled — never
today.** The share sheet falls back to `now`, which is right for a photo shared this minute and
catastrophic for one from 2019: it would file the entry under this week, look completely normal,
and be wrong permanently. The fallback date is **midday on the 1st**, not midnight, because
midnight read in a western timezone is the last day of the previous month — the fallback would
otherwise have been the bug it exists to prevent.

**"Clearly invalid" metadata means a date outside the month being backfilled.** The scan grouped
the asset into that month by its own creation date, so a date outside it did not come from the
grouping — it came from edited metadata, a broken import, or an epoch-zero default. It is refused
and the month stands in.

**Where the suggestion lives is still open**, because the surface was not built. The engine —
scan, clustering, dismissal, caching, date resolution — is complete and tested; Today's lower
region versus Moments versus its own entry point is a design decision that should be made against
the design vocabulary rather than settled by whoever writes the view first.

**Aug 11, 2026** — Phase 18's surface. Where the suggestion lives is now settled, **and the
answer reverses the decision taken earlier the same day.**

**The camera roll is a browse action with its own entry point, not a row inside the composer.**
The morning's decision put a quiet row inside the composer on the freeform path, chosen partly
because it cost the primary action nothing: **+** stayed one tap to a composer. The mockups in
`docs/mobile-app-design-composer/` describe something else — **+** opens an *Add to the archive*
sheet with four capture verbs, and the camera roll sits below a divider as a fifth thing that is
explicitly not a verb, leading to a browse flow of its own: permission explainer, scan, suggested
months, every month, a month picker, then the composer. The prototype carries both options and
argues for this one, on the grounds that browsing and creating are different acts and only the
separated version can say what is actually waiting.

That was raised as a reversal rather than built quietly, and taken deliberately. **The cost is
real and is the thing to watch: every entry now pays a tap it did not pay before**, backfill or
not. If that tap turns out to be the wrong trade, the thing to change is the sheet, not the flow
behind it — the flow is reachable from anywhere.

**A backfill selection is confined to a single day.** The plan allowed multi-select across a whole
month with three photos preselected. `BackfillDateRule` resolves a selection to its earliest
plausible creation date, so a month-wide selection spanning three weeks produces a date that is
defensible and not accurate — the entry lands on the first of those weeks and says nothing about
the rest. Confining the selection to one day makes the resolved date *exact*, which is the only
reason this feature is careful about `occurred_at` at all. The rule lives in `BackfillSelection`
rather than in view state so it can be asserted. **Nothing is preselected:** choosing photos on a
parent's behalf, in the one flow whose entire purpose is getting a date right, would be the app
deciding what a day was about. `suggestedSelectionCount` survives as the framing it always was and
now selects nothing.

**The system photo prompt is earned before it is fired.** iOS asks once and a denial is close to
permanent, and this app deliberately builds no retry funnel. So the explainer comes first, its
three bullets state exactly what the scan does — dates and counts only, nothing uploaded, nothing
added on its own — and "Not now" leaves without asking anything. Nothing in the flow requests
authorization from anywhere else.

**Nothing downloads, at any point.** Thumbnails and full-size reads both run with
`isNetworkAccessAllowed = false`. An asset that lives only in iCloud is *counted* — so the month's
photo count stays honest — *shown* as unavailable, and refused as a selection. Presenting one as
available and then failing on load is worse than saying so, and quietly pulling a few hundred
megabytes from a screen someone opened to browse would break the promise the explainer just made.

**Aug 12, 2026** — Phase 18's follow-up. Four decisions, and none of them reopens the five above.

**`SUGGESTED` is this month in the years before it — five cards at most, floored at the month the
child was born in, and it never substitutes.** It used to be every month that had photos and
nothing written, which on a camera roll starting in 2012 is one card per month back to 2012 for a
child born in 2022 — fourteen years that are not this child's childhood. The section now asks the
same calendar month walking back through up to five prior years, which is a question a parent can
answer. **A candidate that is empty, dismissed, or older than the child shortens the list rather
than being replaced**: the premise is "this month, earlier", and quietly promoting June into an
August slot would break it while looking like it worked. The current month of the current year is
excluded because it is still happening. `EVERY MONTH` is floored the same way and stops at last
month. **Note what this drops:** the old rule excluded months already written about, and the new
one does not — a month with an entry can be suggested again, because "look back at this August"
is a different question from "you have not written about this".

**"What month is it" is answered in the child's `family_timezone`, and the birth month is read out
of the date string.** Two separate ways the same class of defect gets in. `Calendar.current` is the
*device's* idea of the month and is a month wrong on the 1st for a parent travelling — the
`daysUntilExpiry` defect from phase 11 in a second place. And `children.birthdate` parsed to a
`Date` in the device's zone, then read back in the child's, files a child born on the 1st into the
previous month; `BackfillMonth(calendarDay:)` takes the year and month straight out of `YYYY-MM-DD`
with no instant in between, so no zone can move it.

**Every selectable tile in the picker carries its selection ring before the first tap.** The grid's
entire purpose is selection, and a tile with no affordance until after something is already
selected makes the parent's first tap a guess. Unselected is `surface` at 70% under a `border`
hairline; selected fills terracotta with a `canvas` check and puts a 2pt terracotta stroke on the
tile. **A cloud-only tile gets no circle at all** — it is not tappable, and an affordance offering
to select it would be a control that lies. This supersedes the selected-only badge
`docs/design-system.md` described, and that file is updated rather than left to disagree.

**The crash on a long camera roll was the container, not the scan.** A plain `VStack` inside a
`ScrollView` mounts every child before the first frame, so 175 month cards each read a whole month
of the library and requested four thumbnails: 175 reads, 700 requests, 643MB against a 236MB
baseline, measured. **`LazyVStack` alone fixed none of it** — the cards sat inside a nested
`VStack` for their gap, and a lazy stack treats a nested stack as one child. The laziness has to
reach the `ForEach`. Recorded because it is invisible in a diff and reads as already fixed.

**Aug 10, 2026** — Phase 15 made the prompt pool durable. Three decisions.

**Suppression outranks every relaxation rule, including an empty pool.** A dismissed prompt was
excluded only by the same 180-day cooldown as any other, so a question about a mother in a
household where that is painful — or a mission assuming an ability this child does not have —
came back, forever, on a loop. That is a different failure from a repeat: it is the app asking
something the parent has already told it to stop asking. Enforced by removing the prompt from the
candidate pool *before* selection rather than filtering inside the ladder, so no relaxation rung
can resurrect it. Soft-deleted, because a permanent decision a parent cannot undo is worse than no
decision.

**Whether "dismiss" should mean *not today* or *never again* is unresolved, and deliberately
so.** It is a client-side product decision. The server is built so both are expressible:
dismissing an assignment behaves exactly as it did, and suppression is a separate explicit call.
**No client calls the suppression endpoints today.** Resolving this needs a look at how often a
dismissal is really "not this one, ever" versus "not this morning", and that is a question about
the parent rather than about the schema.

**The candidate review CLI flags and never rejects.** A candidate using *precious*, *cherish*,
*treasure* or *little moments*, or opening with a feeling rather than an action, is surfaced with
the rule it tripped so that a rejection is a judgment rather than a guess. The model does not get
to reject its own peers and it certainly does not get to approve them. The decisions file starts
every candidate at `skip`, so a file applied without reading anything changes nothing.

Also confirmed rather than changed: `docs/data-model.md` says the 180-day cooldown relaxes to 90
**before** the age window gives, and the code already did exactly that. A repeat is a mild
annoyance; an age-inappropriate prompt served to a four-year-old is a broken product. There is now
a test that fails if the order is ever inverted, verified by inverting it.

**Aug 10, 2026** — iOS Phase 14 landed push notifications on the client. Six decisions,
all of them about *when* the app is allowed to ask rather than about what it sends.

**The system prompt is never fired directly.** iOS grants exactly one permission prompt per
install and a denial is effectively permanent, so the prompt fires only after the parent has
already said yes to an in-app screen. This is not a dark pattern — it is what stops a "not right
now" from becoming a permanent no. Every path to `requestAuthorization` goes through
`NotificationPreference.acceptSoftAsk` and there is no second route.

**Permission is the last step of onboarding**, after the avatar. The ask arrives to someone who
has already named their kid and chosen a photo, rather than to someone still deciding whether to
use this at all. Child creation moved from the avatar step to the end of the notification step as
a consequence: `finish(with:)` sets `.ready` and lands the parent on Today, so a step after the
create would never have been shown. Onboarding completes identically whether they said yes, no,
or were refused by the system.

**"Not now" is re-offered exactly once, after the first completed entry**, and never again. The
parent has by then experienced the loop, so the offer means something it could not have meant on
day zero. The offer is spent when it is *shown*, not when it is answered — a parent who swipes it
away has answered, and the alternative re-shows it after every entry.

**A system-level denial is terminal.** Nothing re-prompts by any mechanism: not onboarding, not
the post-entry offer, not the Settings toggle. Settings replaces the control with a sentence
naming where the iOS toggle lives. A denied permission is a valid steady state, not a funnel to
recover from. The Settings row must never render as an enabled control that silently does
nothing.

**Notifications are suppressed in the foreground.** The one notification this app sends carries
today's mission, and Today is the screen it would banner over — telling a parent looking at the
prompt about the prompt. Nothing is lost: it stays in Notification Centre. Reversible, and
`docs/Device-Verification/device-verification-push.md` §4 asks for a judgment on it from a real device.

**TestFlight is `production`, not `sandbox`.** `docs/api-contract.md` says otherwise and is
wrong: APNs environment follows the `aps-environment` entitlement in the embedded provisioning
profile, TestFlight builds are signed with a distribution profile, and there is no separate
TestFlight APNs host. Treating TestFlight as sandbox is exactly the defect that makes push work
under Xcode and silently deliver nothing to testers. The client sends `production` for every
non-Debug configuration.

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
