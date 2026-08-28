> **Restored Aug 18, 2026, byte-for-byte from `ec87dbb^`. This file was deleted by accident.**
> Commit `ec87dbb` ("docs rearrane", Aug 16, 2026) moved the `App-Views` design exports around and
> took this file's 229 lines with it. **Nothing referenced the deletion and nothing failed**, so it
> went unnoticed for two days while `CLAUDE.md:7` and `README.md:13` both went on naming it the
> authority on scope — a standing-rules file pointing at a path that returned *No such file or
> directory*. It is the founding document: rules 3, 4 and 5 of `CLAUDE.md` are its design
> principles, nearly verbatim.
>
> **The restore is exact, so two things below are now out of date and are corrected here rather
> than in the text**, because editing a founding document to match the present erases what was
> actually decided at the start:
>
> - **"Working name: TBD"** — the product is **Pocket Chronicle**, settled by the owner Aug 27,
>   2026 on an attorney's trademark-conflict finding, after being `Vellum` from Aug 17
>   (`decisions.md:115`) and `Dogear` from Aug 12. **The name has moved three times; the bundle id,
>   the URL scheme and `manifest.format` have moved none.**
> - **Design principle 5, "Nothing is deleted. Soft deletes only."** — still the rule everywhere in
>   the archive, and **no longer true of accounts.** Phase 66 (Aug 17, 2026) shipped a deliberate,
>   documented exception: a deletion request hard-deletes after seven days, because a soft delete
>   on an erasure would be the service keeping exactly what it was asked to stop keeping. See
>   `data-model.md`'s `deletion_requests` section and open item 14.
>
> Everything else stands as written on Aug 3, 2026.

---

# Memory & Missions — Project Roadmap

**Working name:** TBD
**Platform:** Native iOS (SwiftUI), API-backed. Web client deferred but architecturally reserved.
**Start:** Aug 3, 2026
**First usable build in your own hands:** Aug 14, 2026

---

## 1. What this is

A private archive of a childhood, built one prompt at a time.

Each day the app hands a parent two things: **a question** to answer about their kid, and **a mission** — take a photo, shoot a video, record their voice, or do a thing together. Completed items become entries on a searchable timeline. Years later, the kid gets the keys.

**The one-sentence differentiator:** the camera roll already has the media; this has the *context*, the *prompt that caused it*, and the ability to find it again.

### Design principles

1. **Capture must cost under 15 seconds.** Every feature is measured against the friction it adds to logging.
2. **Missions have three completion shapes** — *did it* (no artifact), *captured it* (media), *wrote it* (text). The inspiration list is mostly behaviors, not artifacts. Don't lose half the product to a media-required schema.
3. **The server is the source of truth.** The phone is a fast, smart client. Never the other way around.
4. **On-device intelligence produces durable data.** Transcripts, captions, and tags are persisted server-side, never regenerated on demand. A future web client will never have an on-device model.
5. **Nothing is deleted.** Soft deletes only. This archive is supposed to outlive the app.

---

## 2. Phases at a glance

| Phase | Window | Goal | Done when |
|---|---|---|---|
| **P0 — POC** | Aug 3–14 | One kid, one parent, daily loop works | You've logged 14 days without cheating |
| **P1 — Daily driver** | Aug 17–Sep 11 | Trustworthy enough that losing data would hurt | Backups, search, widget, 60 days of real entries |
| **P2 — Family** | Sep 14–Oct 9 | Second parent + viewers | Two accounts writing to one child |
| **P3 — Intelligence** | Oct 12–Nov 6 | On-device AI earns its place | Voice is searchable, backfill suggests real memories |
| **P4 — The artifact** | Nov 9–Dec 18 | Year One book | A physical book on the shelf by Christmas |
| **P5 — Public** | 2027 | Only if it takes off | Web client, App Store, other people's kids |

---

## 3. P0 — Proof of concept (Aug 3–14)

Two weeks of evenings. Ruthlessly scoped. The exit test is behavioral, not technical: **did you use it every day for the last week of the build without forcing yourself?**

### In scope
- Single parent account, single child
- ~60 hand-authored prompts across all types
- Server-side daily scheduler: 1 question + 1 mission, weekly bonus on Saturday
- Stacking inbox — items persist until done, dismissed, or expired at 14 days
- Entry composer: text, photo, video, audio; backdating; auto-computed child age
- Timeline: reverse-chronological, year dividers, filter by entry type
- "On this day" surfacing
- TestFlight to yourself

### Explicitly out
Multi-kid UI, viewer access, LLM generation, transcription, print export, widgets, search, push notifications.

### Build order

*Revised Aug 3, 2026. Sprint One planning surfaced a day of ground-zero infrastructure the
original order assumed already existed. Everything below shifts by roughly one day; the
slack on days 11–12 absorbs it.*

**Day 0 — Ground zero**
Apple Developer enrollment submitted (it takes 24–48 hours and blocks nothing else, so it
goes first). Repo, tooling, docker-compose Postgres, CI. Alembic wired before a single
model is written.

**Days 1–2 — Backend skeleton**
Postgres schema (§4), FastAPI endpoints, Sign in with Apple wired into your *own* users table. Deploy to Fly or Railway with Neon. Not Fargate — not yet.

**Days 3–4 — Sync engine**
SwiftData models mirroring the server. Pull-since-`updated_at`, push queue, client-generated UUIDs, idempotency keys. Write this once, carefully; everything else leans on it.

**Days 5–6 — Capture**
PhotosPicker, camera, `AVAudioRecorder`. Presigned multipart upload on a **background `URLSession`**. HEIC→JPEG, EXIF orientation, EXIF `captured_at` → default `occurred_at`. Video poster frames.

**Days 7–8 — The daily loop**
Card stack UI. Done / dismiss. Missed-day handling: items stack, they don't guilt-trip. Server-side expiry job.

**Days 9–10 — Timeline**
Reverse-chron list, year dividers, type filter, entry detail, "on this day."

**Days 11–12 — Slack + polish**
Reserved. It will be consumed by upload edge cases. If it isn't, pull the widget forward.

**Days 13–14 — Live in it**
Backfill 30 real entries from your camera roll. Ship to your own phone. Use it.

### P0 risk list
- **Background upload** is the most likely thing to eat two unplanned days. Prototype it on day 1 as a spike, not on day 5 as a feature.
- **Timezone.** Store a family timezone; compute "today" from it. Otherwise the 5am job hands you tomorrow's mission at 9pm.
- **Scheduler idempotency.** Unique index on `(child_id, assigned_on, slot)`. Reruns must be free.

---

## 4. Data model

Get this right once. Everything after is CRUD.

```
users              id, email, display_name, created_at
credentials        user_id, provider (apple|google|password), subject_id
children           id, name, birthdate, avatar_key, family_timezone
guardians          user_id, child_id, role (parent|viewer), granted_at

prompts            id, kind, cadence, body, theme,
                   min_age_months, max_age_months, month_tags[],
                   completion_mode (did_it|media|text),
                   source (seeded|user|llm), active

assignments        id, child_id, prompt_id?, custom_body?,
                   slot (question|mission|weekly|monthly),
                   assigned_on, expires_on,
                   status (pending|done|dismissed|expired)

entries            id, child_id, assignment_id?,
                   occurred_at, created_at, child_age_months,
                   title, body, unlock_at_age?, deleted_at?

media              id, entry_id, s3_key, kind, captured_at,
                   transcript?, caption?, thumb_key, bytes

tags / entry_tags
```

### Fields that matter more than they look

- **`occurred_at` vs `created_at`** — never conflate. Backdating is a first-class use case, not an edge case.
- **`child_age_months`** — computed at write time and stored. You will want to browse by "age 4" and you don't want to recompute across a birthdate correction.
- **`unlock_at_age`** — nullable. The letter you write about money, the letter about who he is right now: sealed until 16 or 18. Impossible to retrofit cleanly at 500 entries.
- **`completion_mode`** — this is what keeps "never let go of a hug first" a legitimate mission.
- **`assignment_id` nullable** — freeform entries are first-class. Not everything worth keeping came from a prompt.

### Backend contract rules (the web-later insurance)

1. Plain JSON over HTTPS. No Swift-specific serialization anywhere in the wire format.
2. Sign in with Apple is a row in `credentials`, not your identity model. Email/password and Google slot in later with no migration.
3. All scheduling, expiry, and streak logic is server-side. Two phones and a browser must agree on what today is.
4. Media flows device → S3 via presigned URL; the server only ever holds keys and metadata. Same endpoints serve web unchanged.
5. Soft deletes and `updated_at` on everything, from day one.

---

## 5. P1 — Daily driver (Aug 17 – Sep 11)

The goal shifts from "it works" to "losing this would hurt."

- **Full-text search** over entry bodies and titles (Postgres `tsvector` is plenty).
- **Home Screen + Lock Screen widget** showing today's mission. This is the retention lever. Half a day in native, and it's the reason the loop survives week four.
- **Push notifications** — one per day, at a time you choose, silenceable. One. Not two.
- **Share sheet target** so a photo goes from Photos into an entry in three taps.
- **Backups you actually trust** — nightly Postgres dump plus S3 versioning, restore tested once for real.
- **Prompt library to ~200**, hand-written and batch-generated server-side with a real model into a review queue you approve. Seed the ten from the original post as the "Right Now" pack.
- **Random memory resurfacing** on the home screen.

**Exit criteria:** 60 days of real entries, a restore you've actually performed, and a week where the widget was the only thing that reminded you.

---

## 6. P2 — Family (Sep 14 – Oct 9)

- Multi-kid: child switcher, per-child schedules, shared entries that tag both kids.
- Second parent as a full writer on the same child. Conflict handling is simple — last write wins on entries, and a mission completed by either parent completes for both.
- **Viewer role**: grandparents get a read-only feed. No mission inbox, no edit. Invite by link, revocable.
- Per-entry visibility so a sealed letter never appears in a viewer's feed.

**Exit criteria:** two accounts writing to one child for two weeks without a data surprise.

---

## 7. P3 — Intelligence (Oct 12 – Nov 6)

On-device first, cloud only where the small model can't reach. Everything it produces is persisted to the server as plain data.

**Ship in this order:**

1. **On-device speech transcription** (`SpeechAnalyzer` / `SpeechTranscriber`). Audio entries and video audio tracks. Free, private, offline. This is what turns "record his voice" from a shoebox of files into a searchable archive — and it's the highest-value AI feature in the whole product. Transcript syncs to the server, so web search works later without a transcription bill.
2. **Structured extraction with `@Generable`.** Feed a freeform entry to the on-device model, get back a typed struct: people, place, mood, tags, one-line summary. Auto-tagging with no cloud round-trip. This is what a 3B model is genuinely good at.
3. **Camera-roll backfill missions.** PhotoKit scan for clusters from months you have no entries for, surfaced as a mission: "you have 40 photos from last October and nothing logged — pick three." Nothing leaves the device until you choose. Only possible on native.
4. **Device-side personalization.** Server sends the canonical mission; the device rewrites it to use his name, current age, and recent entries. Web later shows the canonical version and degrades gracefully.
5. **Photo captioning** — **blocked on the platform, and the date is unverified.** This line used to say on-device image input "landed in the iOS 27 wave", in the past tense, about a release this repo has never checked; `docs/phases/phase-17.md` then quoted it forward as established. What *is* verified, against iPhoneOS26.4 on Aug 14, 2026: the on-device model's entire input vocabulary is `Transcript.Segment`, which is text or structure and nothing else. There is no pixels-to-prose API to call. See `docs/blocked.md` §9 for the grep that re-checks it. A bonus, never a dependency.

**Guardrails:**
- Gate every call behind an availability check and degrade silently. Not every device qualifies.
- Never let the on-device model author the mission library. Small model, weak world knowledge, and those prompts are the soul of the product. Authoring stays server-side with a real model plus your review.
- The framework's provider layer means your call sites don't change when you later route a hard task to Private Cloud Compute or a third-party model. Write against `LanguageModelSession` and keep the option open.

---

## 8. P4 — The artifact (Nov 9 – Dec 18)

The thing that makes the whole exercise real: **Year One, printed.**

- Annual export: every entry for a calendar year, chronological, with photos laid out and questions answered.
- Videos and audio can't go in the book — put a QR code where they'd be. It resolves to a playback page. (First real reason to build a small public web surface — a good, contained excuse to prove the API works from a browser.)
- PDF generation server-side, sent to a print-on-demand service.
- **Hard deadline: a physical book on the shelf by Christmas.** This is the forcing function for the whole year.

---

## 9. P5 — Public (2027, conditional)

Only if you still want it after the book exists.

- Full web client against the same API. Should be a client project, not a backend project — if it isn't, P0's rules were violated somewhere.
- Onboarding, subscription, App Store review, privacy policy.
- **Children's data raises the compliance bar.** The account holder is the parent, and the child isn't a user until the handoff — but a product built around a database of kids' photos, voices, and locations needs a real legal review before a single stranger signs up, not after.

---

## 10. Open decisions

| # | Decision | Needed by | Notes |
|---|---|---|---|
| 1 | Handoff age — 10, 13, 16, or 18? | P4 | Affects `unlock_at_age` defaults and how you write. Can be per-entry, so this is a default, not a lock-in. |
| 2 | What the handoff *is* — an account, an export, a device? | P5 | Worth deciding before you write 500 entries addressed to someone. |
| 3 | Name | P1 | You'll want it for the widget and TestFlight. |
| 4 | Mission tone — warm, playful, or plain? | P1 | Set it before authoring 200 prompts, not during. |
| 5 | Streaks: yes or no? | P1 | Retention lever, but a guilt engine on a parenting app. Lean no. |

---

## 11. Standing risks

- **Scope creep via mission types.** Every new `kind` costs a composer surface. Add one per phase, maximum.
- **The two-week POC slipping into six.** The exit test is usage, not completeness. Ship ugly.
- **Media cost drift.** Video at original quality across two kids for eighteen years is real money. Decide a transcode policy in P1, not in year three.
- **The archive outliving the app.** Build a full export — a folder of files plus a JSON manifest — before you'd ever need it. P2 at the latest.
