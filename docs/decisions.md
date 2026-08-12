# RASCAL — Decision Log

Read this before proposing anything. Settled decisions are settled; don't relitigate them without new information.

Last updated: **Aug 11, 2026** — four open items answered (4, 6, 7, 8) and one unblocked (10).

---

## Settled

### Product

| Decision | Rationale |
|---|---|
| ~~One question + one mission per day~~ — **superseded Aug 11, 2026** | Borrowed from Paired. Two items is the most that survives a bad Tuesday. **The day is three items now** — see "Three daily assignments" below, which supersedes this and says what it cost. Left in place rather than deleted because the two-item rule is the reason the letter sits on the 15th and not the 1st, and that split still stands on its own. |
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
| **Mission tone is warm and cheerful** — settled Aug 11, 2026, closing open item 4 | The seed library leans dry-and-specific and that was never confirmed as a choice, only as a habit. Warm is the answer, and it is the same voice the app already speaks in everywhere else — the design direction is "warm, friendly, polished", the completion motion is "satisfying, quiet", and there are no streaks and no guilt copy. A dry library inside a warm app is two products. **Warm is not the same as cute, and it is not the same as vague:** the thing that makes these prompts work is that they ask for one concrete observable thing, and specificity survives the tone change intact. "What noise in the house makes him look up right now?" is already both. The consequence is forward-looking rather than retroactive — see the changelog entry; the 113 seeded prompts are not being rewritten for tone. |
| **One notification a day, at a time the parent sets, defaulting to 19:00** — settled Aug 11, 2026, closing open item 6 | The question was "what time actually works", and the answer is that the product should not need to know. What shipped is already right: one a day, `notification_time` on the user, 19:00 as the default, and every user free to move it. 19:00 keeps its rationale — early evening, parent and child together, a question answered over dinner, a mission that stacks to tomorrow at no cost. This closes the item as *the existing design is the answer*, not as a new decision. |
| **A second child is P2 work, taken up when P2 is** — settled Aug 11, 2026, closing open item 7 | Not a question any more and not a thing to solve early. The schema has supported multiple children since the first migration and the client already has a switcher from Today v2, so nothing is being deferred that would be expensive to add later. The remaining cost is per-child scheduling and the UI around it, and that is P2's to pay when P2 starts. Do not build toward it in P0 or P1. |
| **The printed book includes did-it entries** — settled Aug 11, 2026, closing open item 8 | Yes, unreservedly. This is rule 4 of the standing rules applied to the artifact: "get on the floor for ten minutes" is a complete, legitimate entry, and a book that silently dropped every entry without a photo would tell a version of the childhood filtered by whether someone happened to have a camera out. The worry the item recorded — that a page of behaviours may read empty — is a **layout** problem and gets a layout answer: did-it entries are set as text, grouped, with the date and the prompt they answered, rather than as photo pages with a hole where the photo goes. P4 owns that design; what is settled is that they are in. |
| **One notification a day. Not two, under any name** | No reminder, no digest, no weekly summary, no "you have 3 waiting". The roadmap says one and it means one. A second daily notification is the point at which a warm app becomes a nagging one, and there is no path through the send job that can produce two. |
| **A finished day is silent** | If every item for today is done, nothing is sent — no "great job", no summary, no streak. A parent who completed the day should not be pinged about it, and a congratulation is still an interruption. This is the no-guilt rule applied correctly, and it is the rule most likely to be eroded by a well-meaning addition. |
| **The notification carries the mission, and never the archive** | The mission body, optionally the child's first name, and the assignment id for the deep link. Never entry content, never anything from a sealed entry, never a count of waiting or missed items. It renders on a lock screen other people can see: a sealed letter is addressed to one person eighteen years from now, and a backlog number there is a guilt engine you cannot look away from. The message type has no field that could carry any of it, so this is enforced by the shape rather than by care. |
| The notification preference lives on the **user**, not the child | One human decides when their own phone buzzes. A second guardian on the same child is a second phone with a second opinion, and per-child preferences would be a matrix nobody asked for. It is surfaced on the existing `GET /me` and `PATCH /me` rather than a preferences endpoint, so a client that already reads `/me` on launch needs no second call. Off by default: the client turns it on after the parent grants OS permission, never before. |
| Default notification time is **19:00**, and it is a default rather than an answer | Early evening: the parent is with the child, a question is answered in conversation over dinner, and a mission not done tonight stacks to tomorrow at no cost. Open item 6 — what time actually works — is still open, and every user can change it. |
| A missed send window is **dropped after two hours**, never fired late | Phase 12 made a missed *assignment* self-repairing, because `GET /today` fills the day on read. **A notification has no read to repair it** — nothing calls anything at 19:00 on the user's behalf — so the job is catch-up capable instead: every run sends anything whose window has passed today and has not been sent. The tolerance is what stops catch-up becoming a 2am notification about a day that is nearly over, or a job that was down for a day waking every user at once when it comes back. Two hours because Fly's coarsest schedule is hourly, so a window is already up to an hour old before any run looks at it, and two hours absorbs exactly one entirely missed run while still never reaching the middle of the night from a daytime window. |
| A device is unique on `(token, environment)`, and `environment` has no default | A sandbox token and a production token are different tokens addressed to different APNs hosts, and sending to the wrong one **fails silently**. This is the single most common way push works in development and not in TestFlight. Collapsing them onto one row would mean whichever build launched last silently won. The client is the only thing that knows which build it is, so the API refuses to guess. |
| One notification per user per day is guaranteed by a **unique index**, not by a check | `notification_sends` is unique on `(user_id, notification_date)` and the row is claimed with `ON CONFLICT DO NOTHING` *before* anything reaches APNs — exactly how `assignments` makes the scheduler free to re-run. A read-then-write would let two overlapping runs both read "not sent" and both send. Written before the push rather than after, so a crash between the two costs one notification instead of sending one on every retry. |
| The claim is **committed** before the push, one transaction per user — the send job is not atomic, on purpose | The unique index only orders two runs that overlap; it does nothing about one run that dies. An APNs push is the single side effect in this service that a rollback cannot undo, so a run wrapped in one transaction would roll back every claim it had made while the phones those claims covered had already buzzed — and the next hourly run would send them all a second time. Committing per user costs the opposite failure: a crash in the window between the commit and the send loses that user one notification. For a product whose first rule is "one a day, not two, under any name", losing one is the right side of the trade. The consequence to hold onto is that `run_notifications` commits, so nothing but the job may call it. |
| An unreadable `APNS_PRIVATE_KEY` fails at **startup**, not at the first send | A `.p8` that lost its newlines on the way into a secret is the likely first-deploy mistake, and it is unreadable in a way nothing notices until something signs with it. Discovered at send time it is the worst possible moment: the day has already been claimed and committed, so the user is recorded as notified, hears nothing, and is skipped tomorrow as "already sent" — a permanent silent miss from a typo. `build_push_client` signs one throwaway token before any user is read, so a bad key is a hard exit that claims nobody and is fully recoverable by fixing the secret. `ApnsClient.send` also degrades a signing failure to a result rather than an exception, because an error escaping mid-run costs every *remaining* user their notification too. |

| **The handoff is a family-decided moment, not an age — with a floor of 13 on self-owned access** — settled Aug 11, 2026, closing open items 2 and 3 | Two mechanisms, and only one of them has a number on it. **Reading it together** needs no account and no age: it is the parent's phone, handed over, scrolled through together. That is available today, needs nothing built, and is what "when the family decides" describes for the next nine years. **His own account** has a floor of **13** — not as a preference but as a constraint. Below 13 he cannot hold his own Apple ID without family-managed consent, and COPPA attaches to any account created for him, so a pre-13 self-owned handoff would mean building parent-proxy auth for one user. When to cross that line is the family's call; that it cannot be crossed before 13 is not. The shape is **shared access, not transfer**: the child becomes a second `users` row with a guardian-style role of `subject` against the same archive, and the parent keeps theirs. `POST /children/{id}/guardians` already exists as a P2 stub and the schema separates `users` from `credentials`, so nothing needs building now. |
| **No global default for `unlock_at_age`** — settled Aug 11, 2026, part of closing open item 2 | The item asked for a default on the grounds that it "changes how you write". It does — but it changes how you write *each letter*, which is why it is already per-prompt. The seeded library varies it deliberately: **13 for the birth-story letter, 18 for the money one**, and that variance is the feature. Adding a global default would either be ignored by every prompt that overrides it or would flatten a distinction that was made on purpose. Authored per letter. Both values in use. |
| **No separate "visible to the child" flag. `unlock_at_age` is the only mechanism** — settled Aug 11, 2026, falling out of open item 3 | The obvious follow-on question to a handoff is whether some entries stay hidden after it. The answer is no, and the reason is structural rather than sentimental: unsealed means visible the day he has access, sealed means visible at its age, and those two states cover everything. A third state would mean writing entries into his archive that are being kept from him, which is a different product. If a particular entry should wait, that is what a seal is for. **This is worth recording because it is a column not being added** — the cheapest kind of decision to reverse and the most expensive to have added speculatively. |
| **The export gets a readable layer: a static HTML site inside the same zip** — settled Aug 11, 2026, closing open item 9 | The item's note said "folder of files + JSON manifest", and that shipped — `manifest.json`, `entries.json`, `media/YYYY/MM/`. What it is not is the thing you hand to a thirteen-year-old. So the archive has **three layers, and only the middle one was missing**: the **backup** (the zip as it exists, lossless, for machines and migration — unchanged), the **readable archive** (`index.html` + `assets/`, added to the same zip), and the **printed book** (P4, already settled). The readable layer is a pure function of data already emitted, so there is no second export path and no second source of truth. **Static HTML rather than PDF**, and the reason is not preference: PDF is fixed-layout and cannot hold audio or video, and this archive's distinguishing content is a four-year-old's recorded voice. A format that drops it is not a copy. PDF stays available as a derived artifact generated later from the same data. |
| **Sealed letters export in the clear and the viewer renders the seal honestly** — settled Aug 11, 2026, part of open item 9 | `entries.json` keeps sealed bodies in the clear, which was already settled and does not change: an export you cannot read is not a backup. The viewer computes the reader's age from the manifest's birthdate and shows a not-yet-due letter **as sealed, with the date it was written and the age it opens at — and lets him open it anyway**. This is an honesty affordance, not security. The body is in a plain text file three inches away, and an archive that pretended otherwise would be lying to the person it belongs to. No encryption, no obfuscation, and no omitting sealed bodies from `entries.js` — forking the viewer's data from the backup's would create exactly the second source of truth this design exists to avoid. |

| **Onboarding asks for pronouns, after birthdate, and skipping is a finished setup** — settled Aug 11, 2026, closing the collection half of open item 10 | `children.pronouns` has existed in Lane A since before Aug 11 and nothing writes to it. The reason onboarding gave for not asking — "asking and then discarding would be worse than not asking" — expired the day the column landed, and the item has been miscategorised as blocked ever since. It goes **after birthdate and before timezone**, because name and birthdate are facts about the child and timezone is a fact about the household. **It is skippable and nothing is preselected.** A skipped pronoun stores `null` and is a complete setup, exactly as a skipped avatar is; a preselected he/him would be an assumption wearing a default's clothes, and a parent tapping past it would not have answered. Settings offers the same choice through the sheet `ChildHeroCard` already routes Birthday and Timezone to. |
| **They/them are the canonical token keys** — settled Aug 11, 2026, part of open item 10 | Three schemes were considered. Grammatical abbreviations (`{subj}`, `{obj}`, `{poss}`) are precise and unreadable — you cannot proofread a sentence you cannot hear, and prompts get written at eleven at night. He-forms as keys (`{he}`, `{his}`) read naturally and match the existing library, but **`{his}` is ambiguous** between the determiner ("his favourite") and the possessive pronoun ("that one is his"), which they/them splits into "their" and "theirs" — so a he-keyed table cannot be substituted correctly, and the bug would stay invisible until someone set she/her. **They/them is the only English pronoun set whose five slots are five distinct words**, which is the entire argument: it is the only set that can serve as a key without collision, and it reads aloud. |
| **Verb agreement is four explicit compound tokens, never conjugation** — settled Aug 11, 2026, part of open item 10 | "he is" / "she is" / "they are" cannot be fixed by a pronoun token, because the verb changes too. A conjugator that inflects the word after `{they}` is real natural-language work, gets irregulars wrong, and **fails silently** — which is the disqualifying property, not the difficulty. `{they_are}`, `{they_were}`, `{they_have}` and `{they_do}` are a lookup table that is correct always, and the author decides at write time. A conjugator is correct usually, and "usually" is not a property a permanent archive gets to have. |
| **Capitalisation is explicit, never positional** — settled Aug 11, 2026, part of open item 10 | `{They}`, `{Them}` and `{Their}` exist as separate tokens rather than being derived from a token's position in the string. A prompt can legitimately begin mid-thought, and a positional rule would be wrong somewhere across an eighteen-year archive with nobody watching the place it was wrong. |
| **Tokenised and literal prompts coexist permanently. The 113 seeded prompts are not rewritten** — settled Aug 11, 2026, part of open item 10 | The renderer passes text containing no tokens through byte-identical, so the seeded library — which is literal he/him and contains no braces — renders exactly as it does today, forever, with no migration. This is the same reasoning that kept those 113 out of the mission-tone rewrite under item 4: a bulk edit of serving content is large, risky and low-value, and `test_seeding.py` asserts a coverage table a sweeping edit would have to be reconciled with by hand. **The decision binds what is authored next**, not what exists. |
| **An unknown token renders literally, braces and all, and never throws** — settled Aug 11, 2026, part of open item 10 | `{foo}` stays `{foo}` on the card. In a permanent archive a visible `{foo}` is a bug someone can see and fix; a silently-dropped one is a sentence that lost a word, and nobody will ever know which word it was or that it was ever there. This is an assertion in the test suite, not a comment. |
| **A null pronoun renders the they/them column** — settled Aug 11, 2026, part of open item 10 | They/them is grammatical for every child, so an unanswered question degrades to correct English rather than to a placeholder, a guess, or a default that implies an answer nobody gave. |
| **Prompt bodies are stored with tokens intact. Every client renders; the server never does** — settled Aug 11, 2026, part of open item 10 | The same body reaches a phone, the browser client reserved for 2027, an export and a printed book, and a body pre-rendered on the server cannot be re-rendered when the answer changes. The rendering happens at the last moment before a human sees the sentence — **including for the widget, where "the last moment" is when the app writes the snapshot**, not inside the extension, because the extension does no work of its own. |
| **`{name}` at most once per prompt, and only where a parent would say it aloud** — settled Aug 11, 2026, closing the naming half of open item 10 | This is an authoring rule more than a mechanism. "What made {name} laugh today?" reads warm. "What did {name} do when {name}'s cousin arrived?" reads like a mail merge, and the second one is what happens by default when a token is available and nobody said how often to use it. Pronoun tokens carry every other reference. The rule goes in `docs/mission-library.md`'s style-reference section, because `scripts/generate_prompts.py` reads that file on every run and the tone of future batches drifts toward whatever the library actually contains. |

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
| **Three daily assignments, not two: `question`, `mission`, `mission_b`** | The day was one question and one mission. It is now a question, a photo mission, and a second mission drawing video, audio and activity. The old pairing made photo compete with everything else in one pool, so a parent could go a fortnight without being asked for a photo — the artifact the archive is most made of — while the same pool also decided whether they were ever asked to record his voice. Splitting them means both get asked for every day. The cost is stated in the next two rows and is real. |
| **`mission` narrowed to photo-only and kept its name** | Renaming it to `photo` would mean migrating every existing assignment row and touching the widget, the push ladder, the Today board and the suite, for a cosmetic gain. **So `mission` means something narrower after migration 0008 than it did before it, and rows on either side of that line are both correct.** A `mission` row from July holding an activity prompt is not a bug and must not be "fixed": it is what was served that day. If you are reading this because you found one, that is why. The name is a slot identifier, not a description of the kind. |
| **The weekly, monthly and letter slots fire on top of the daily three, never instead of them** | A Saturday is four items, the 15th is four, and a Saturday that is also the 15th is five. Suppressing the third mission on those days was considered and rejected: a day that quietly serves less is harder to reason about than a day that occasionally serves more, and nothing in the product requires the parent to finish everything — items stack, and stacking is explicitly fine. This raises the old "two items is the most that survives a bad Tuesday" ceiling, deliberately and with the worst case known. |
| The three daily picks avoid each other's themes, by construction rather than by counting | Each assignment is inserted before the next slot is selected, and the theme window includes the current date — so the third pick sees the first two exactly as the second saw the first. The rule was written for a pair and needed no change for a trio, which is the property to preserve if a fourth daily slot is ever added. When no fresh theme is available the ladder relaxes and serves a repeat: a theme collision is a preference lost, an empty slot is a hole in the day. |
| **A letter can be written on any day. The 15th is the reminder, not the permission** — settled Aug 11, 2026. **Decided, not yet designed or built** | The seal control shipped complete and reachable only from a `letter` assignment, which the scheduler creates only on the 15th (`SealControl.isOffered` requires `promptKind == .letter`; `slots_for` appends `letter` only when `day.day == 15`). That made the monthly *slot* into a monthly *ration*, which was never the decision — the slot exists so a letter cannot lose a coin flip to a height measurement, and nothing about that reasoning says the thought has to wait twelve days for the form. A letter that occurs to you on the 3rd currently has nowhere to go: the **+** composer has no assignment, so it can never seal, and the entry is readable immediately. **This does not change the scheduling decision above** — the 15th keeps its slot and its prompt. It adds a way in. Design is being done in Claude Design; the API needs no change, because `POST /entries` already accepts `unlock_at_age` and now reads its setness correctly. Two things left open for the design to answer: whether the any-day path writes against a `letter` prompt or is freeform-plus-seal, and where the entry point lives — the *Add to the archive* sheet behind **+** is the obvious candidate, since Phase 18 already put one there. |
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
| **`GET /today` creates the day's missing assignments itself. The scheduler is an optimisation, not a dependency** | The scheduler runs on a machine, and a machine can be stopped, restarting, or on the wrong side of an outage at 5am. The failure is silent and unrecoverable in the way that matters: the Today screen is simply empty, which reads as a broken product rather than a sleeping machine, and tomorrow's run fills tomorrow — the day does not come back. So the read repairs it, on the child's local date, using `ensure_day_filled`, which is the scheduler's own `slots_for` and `_fill_slot` and therefore the same cooldown, theme rotation, age window and seasonal filter. A second selection algorithm would diverge invisibly and cost the archive years of variety before anyone noticed. Correctness under two simultaneous readers is the `(child_id, assigned_on, slot)` unique index, not the cheap existence check in front of it. Two things it deliberately does not do: it does not expire lapsed work, and it does not honour `?date=` — a read endpoint that can be made to write assignments into an arbitrary past or future is a worse thing than an empty screen. |
| Scheduler durability under Fly is `min_machines_running = 1` plus the read path, not a trigger endpoint | Three options were on the table. An authenticated trigger endpoint is a new public route, a new secret, and a new caller to keep alive — more moving parts to protect a thing that is now only an optimisation. A dedicated scheduled machine already exists and stays, but it cannot be the guarantee: `fly deploy` neither creates nor updates it, so a fresh app has no scheduler until someone runs `fly machine run` by hand, and the machine it creates pins its image and can quietly run months-old code. `min_machines_running = 1` is the boring one, costs roughly $3/month for a shared-cpu-1x/512mb machine at Fly's published rates, and buys the thing that actually matters — the machine serving the read-path safety net is always awake. What the scheduler is still genuinely needed for is expiry, which the read path deliberately does not do; without it the `waiting` list grows without bound, which is a slow product problem rather than data loss. |
| Neon: the app uses the **pooled** endpoint, Alembic uses the **direct** one | Neon's pooled endpoint is PgBouncer in transaction mode. A long-lived FastAPI process wants it — the app holds a SQLAlchemy pool for the life of the machine and Neon's connection ceiling is the scarce resource. A migration cannot use it: session-level advisory locks, prepared statements and some DDL are exactly what transaction-mode pooling does not carry, and the failure names neither pooling nor Alembic. `DatabaseSettings.sync_database_url` prefers `DIRECT_DATABASE_URL` and falls back to `DATABASE_URL`, which is right locally where there is no pooler and is the reason forgetting it in production makes every deploy's release command a coin flip. |
| `S3_REGION` and `S3_ENDPOINT_URL` are `fly.toml` `[env]` values, never Fly secrets | Neither is sensitive, and both were getting the deployment wrong from opposite directions: `fly.toml` shipped `S3_REGION = "us-east-2"` — the exact value `docs/tigris-setup.md` calls the single most likely way to break Tigris — while `S3_ENDPOINT_URL` was set nowhere at all, and unset means real AWS. Presigning is an offline signature computation, so neither mistake fails at boot or reddens a health check; the app hands the phone an `amazonaws.com` URL that 403s, in production only. Putting them in `[env]` makes them auditable at a glance and, unlike a secret, reviewable in a diff. They must not *also* be set with `fly secrets set`: when a name is in both, precedence is a detail of flyctl's version, and configuration nobody can reason about at 11pm is worse than configuration that is wrong. |
| Bundle id is `com.travisterry.childarchive` | A bundle id is permanent and the app name is still open, so it is deliberately name-neutral — RASCAL, SMALL FRY, or anything else can ship on top of it. Settled before the Xcode project exists, because changing it afterward means redoing signing and the Sign in with Apple registration for nothing. `APPLE_BUNDLE_ID` must match it: it is the `aud` claim every Apple identity token is verified against. |

| **The export viewer is generated on the fly and stored nowhere** — settled Aug 11, 2026, part of open item 9 | `index.html`, `assets/app.css` and `assets/app.js` are **constant for every export and every child**, so they live in the repo as static assets and are copied into the zip during the assembly pass that already writes the manifest. The only generated file is `entries.js` — the bytes of `entries.json` with `window.RASCAL_ARCHIVE = ` in front. Nothing is cached, nothing is per-user, nothing is stored. |
| **The export viewer runs from `file://` with no build step, no network, and no framework** — settled Aug 11, 2026, part of open item 9 | This is the whole point of the layer and it is where it would be easy to be clever. **No npm, no bundler, no CDN, no web fonts, no analytics, vanilla JS, relative paths, system fonts.** What is in the repo is what ships. The constraint is not aesthetic: a viewer that needs a package manager to open is a dead archive, and the person opening it will be doing so in a decade with nobody around to fix it. `entries.js` exists rather than `entries.json` alone for the same reason — **browsers block `fetch()` from a `file://` origin**, so a double-clicked `index.html` cannot read a JSON file next to it, but a `<script>` tag works. That single constraint decides the file layout. |

### Design

| Decision | Rationale |
|---|---|
| Warm, friendly, polished — Journey and Raven register | Two attempts at an art-directed riso/poster direction were rejected. |
| Terracotta `#C05A2B` primary, periwinkle `#5566D6` secondary | Derived from the reference screenshots, not invented. |
| Cream canvas `#FDFAF4`, navy-charcoal ink `#23253C` | Never pure white, never pure black. |
| Color carries meaning: orange = missions/photos, blue = questions/voice | Not decoration. |
| Timeline is a scannable date-grouped card list with thumbnails | Not a full-bleed story feed. Every reference app does it this way. |
| Completion = circular terracotta checkmark + spring + haptic | Satisfying, quiet, repeatable. No stamp, no confetti. |
| Light mode only for now — **except the widget, which has no choice** | Dark mode is P2 at the earliest for the app. A widget follows the system appearance and cannot opt out: there is no `preferredColorScheme` for a widget, and a cream card on a dark Home Screen is a bright rectangle in someone's evening. Scoped to the widget target, and it is an exception rather than a reversal — see the Aug 10 changelog entry. |
| The widget reads a file the app writes; it never calls the API | A token refresh running inside an extension, concurrently with the app, can invalidate the app's own session, and the failure is intermittent and expensive to trace. Staleness is the price, and it is paid honestly: a snapshot whose day is not today renders neutral. |
| **The share extension stages into the App Group and exits; the app drains it. No networking in any extension, ever** | Three separate reasons, each sufficient. A share extension runs under a hard memory ceiling and a 4K minute is ~250MB, so a transcode or an upload there is a crash waiting for a large file. A token refresh inside an extension can invalidate the app's own session — the same reason the widget has no network, and the failure is intermittent and very hard to attribute. And media may not upload until the server has acknowledged its entry, because `POST /media/upload-url` needs an `entry_id` it recognises; an extension uploading independently breaks that ordering and 404s. The cost is a delay between sharing and the archive holding it, which is invisible: the entry exists locally the moment the extension exits. |
| **A shared photo's `occurred_at` is read from the file's capture metadata, and the fallback is recorded as one** | A photo shared from Photos is usually not from today. Defaulting to now files a 2023 photo under this week, and the mistake is invisible — the entry looks completely normal, on the wrong day, permanently, in a record whose whole claim is that it knows when things happened. So EXIF `DateTimeOriginal` for a photo and the asset's creation date for a video, the **earliest** among them for a multi-select, and `now` only when nothing carried a date at all. Which of the two it was is stored on the record, so the extension can say "today is standing in" rather than leaving a parent to infer it. `created_at` remains the moment Save was pressed; the two are never conflated. |
| **One share is one entry, however many files it carried** | Three pictures of the same afternoon are one thing that happened, and the composer has treated a multi-select that way since phase 2. One entry per photo would fill a timeline with fragments of a single moment. |
| **Sharing the same photo twice makes two entries. There is no deduplication** | Not an omission. An `NSItemProvider` carries no asset identifier, so the only reliable key is the content — and hashing a video inside the process with the memory ceiling is exactly what this design exists to avoid. It is also not clearly the wrong behaviour: the same photograph attached to two different days is a legitimate pair of entries, and a heuristic that silently dropped the second would destroy a real one. Within a single share duplication is impossible, because the entry's UUID is written into the record by the extension. |
| Light mode applies to the share extension, unchanged | The widget's dark palette is an exception granted because a widget has no `preferredColorScheme` and cannot decline the system appearance. A share extension can, and does — `overrideUserInterfaceStyle = .light`. The exception was scoped to the widget on purpose and is not a precedent. |
| No count of anything on the widget — no backlog, no streak, no ring, no percentage | "No streaks, no guilt copy" already applies everywhere; the widget is where it matters most, because a number of outstanding items is parked in the one place a parent cannot look away from. `waiting` is never read when building the snapshot. |
| Lock Screen accessory widgets distinguish mission from question by SF Symbol and type hierarchy, never colour | Accessory families render as a monochrome mask, so terracotta-means-mission and periwinkle-means-question say nothing there. The symbol is the one the `PromptCard` already uses, so the Lock Screen inherits the app's vocabulary rather than inventing a second one. |
| Floating pill tab bar with center + FAB | Straight from the references. |
| Destructive and irreversible actions are isolated in a separate bottom card, never adjacent to ordinary edit rows | A divider between two rows says "these belong together"; a gap says "these do not". Recomputing every stored age in an archive is not a neighbour of changing a name, and a mis-tap between the two is not recoverable by tapping again. |

### The pronoun token table, as a contract

Every consumer honours this: the iOS client, the browser client reserved for 2027, the export's
HTML viewer, and the printed book. Fourteen tokens, one dictionary, no logic.

| Token | he/him | she/her | they/them | null |
|---|---|---|---|---|
| `{they}` | he | she | they | they |
| `{them}` | him | her | them | them |
| `{their}` | his | her | their | their |
| `{theirs}` | his | hers | theirs | theirs |
| `{themself}` | himself | herself | themself | themself |
| `{they_are}` | he is | she is | they are | they are |
| `{they_were}` | he was | she was | they were | they were |
| `{they_have}` | he has | she has | they have | they have |
| `{they_do}` | he does | she does | they do | they do |
| `{They}` | He | She | They | They |
| `{Them}` | Him | Her | Them | Them |
| `{Their}` | His | Her | Their | Their |
| `{name}` | the child's given name, identical in every column | | | |

Three invariants, all of which are assertions:

1. Text containing no tokens passes through **byte-identical**.
2. A null pronoun renders the they/them column.
3. An unknown token renders literally, braces included, and does not throw.

### Rejected — do not revisit

- Risograph, halftone, misregistration, screen-print aesthetics
- **Paper grain — the tiling `feTurbulence` noise overlay, named explicitly as of Aug 11, 2026.**
  Three design exports in a row (Today v2, Settings v2, Entry Detail v2) have shipped it as
  `--rascal-grain` and described it as mandatory identity — *"A RASCAL screen without grain looks
  wrong."* Three importers in a row dropped it and left it open, because the line above says
  "screen-print texture" and a reader deciding about a 5%-opacity noise layer does not reliably
  see themselves in that phrase. **It is the same rejection. It is now written in the words the
  exports actually use, so the next import can close it by reading rather than by asking.**
  The exports will keep carrying it; that is a property of the design system they come from, not a
  new argument.
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
| ~~2~~ | ~~Handoff age — 10, 13, 16, or 18?~~ | ~~P4~~ | ✅ **Answered Aug 11, 2026 — no global default; 13 is a floor on self-owned access, not a default seal age.** Settled above. `default_unlock_age` stays per-prompt; 13 and 18 are both in use in the seeded library and that variance is deliberate. |
| ~~3~~ | ~~What the handoff actually *is* — an account, an export, a device, a printed set?~~ | ~~P5~~ | ✅ **Answered Aug 11, 2026 — a family-decided moment, shared access rather than transfer, with the export as the durable floor.** Settled above. Nothing to build now; `POST /children/{id}/guardians` is the seam. |
| ~~4~~ | ~~Mission tone — warm, plain, or dry?~~ | ~~P1~~ | ✅ **Answered Aug 11, 2026 — warm and cheerful.** Settled above. Applies to prompts authored from here on, including the 79 candidates awaiting review; the seeded 113 are not being rewritten for tone. |
| ~~6~~ | ~~Push notification time~~ | ~~P1~~ | ✅ **Answered Aug 11, 2026 — one a day, parent-settable, 19:00 default.** Settled above. What shipped was already the answer; no code changes. |
| ~~7~~ | ~~Second kid — when?~~ | ~~P2~~ | ✅ **Answered Aug 11, 2026 — when P2 comes up, not before.** Settled above. Do not build toward it in P0 or P1. |
| ~~8~~ | ~~Does the printed book include did-it entries?~~ | ~~P4~~ | ✅ **Answered Aug 11, 2026 — yes.** Settled above. The "may read empty" worry is a layout question for P4, not a question about whether they belong. |
| ~~9~~ | ~~Full export format~~ | ~~P2~~ | ✅ **Answered Aug 11, 2026 — the existing zip plus a static HTML viewer inside it.** Settled above. Generated on the fly, stored nowhere, runs from `file://`. Prompt: `lane-a-export-html-viewer.md`. |
| ~~10~~ | ~~**Pronouns, and where the child's name appears in prompts**~~ | ~~P1~~ | ✅ **Answered Aug 11, 2026 — collected in onboarding and Settings, rendered from a fourteen-token contract, and the 113 seeded prompts are untouched.** Settled above, with the token table as a wire-format contract in `docs/api-contract.md`. **The client work is unstarted and has no phase number** — the number this was drafted against, phase 20, has since shipped as the nine TestFlight defects (PR #47). |

---

## Changelog

**Aug 11, 2026** — **Open item 10 closed in both halves, and it is the last one but the name.**
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
`test_seeding.py`'s coverage table to disagree with. The decision binds the **79 unreviewed
candidates** and every batch after them — and those 79 are not being edited in this phase, since
they are awaiting a human read that has not happened and rewriting them here would consume that
review without anyone having done it.

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

**That makes the 79 unreviewed candidates the first thing this decision touches.** They were
generated with `docs/mission-library.md` as the style reference — that is, against the dry
library — so they inherit the tone that was just changed, and they are sitting in
`docs/prompt-candidates/` waiting on a human read that has not happened. Read them for warmth as
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
cannot be measured anywhere but on a phone, and `docs/device-verification-share-extension.md` §3
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
`docs/device-verification-push.md` §4 asks for a judgment on it from a real device.

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
