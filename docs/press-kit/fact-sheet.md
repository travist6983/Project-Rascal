# Pocket Chronicle — press fact sheet

Every claim below was checked against the tree on Sep 7, 2026 — the iOS source, `docs/api-contract.md`,
the marketing site's page copy, and App Store Connect notes in `docs/blocked.md`. Where the source and
a marketing sentence disagree, the disagreement is named rather than smoothed over. **Do not add a
claim here without a file to point at.**

## One line

Pocket Chronicle is a private, prompted archive of a child's childhood for iPhone: two prompts a day —
a question, and a small mission to photograph, film, record or do — answered in about fifteen seconds
and filed with the prompt that caused it and the child's exact age, on a timeline the kid inherits.

*"Searchable for the next eighteen years" is a framing of what the archive is for, not a retention or
uptime guarantee. Do not quote it as a promise.*

- **Tagline:** One question a day. A childhood you can find again.
- **App Store name and subtitle (live listing):** "PocketChronicle.App" — "One prompt a day, kept forever"
- **App Store link:** https://apps.apple.com/us/app/pocketchronicle-app/id6800155810
- **Website:** https://pocketchronicle.app · **Press contact:** hello@pocketchronicle.app
- **Instagram:** @pocketchronicle.app
- **Home-screen label:** `Chronicle`
- **Made by:** Travis Terry, a dad, solo. No company, no investors.

## The founder's story (use it — it is the pitch)

Travis is a dad who forgets to take pictures. When he does remember, a year later he cannot say what
was happening in the photo or why he took it. The camera roll remembers what the kid looked like and
nothing about what they were like. Pocket Chronicle is the fix he built for himself: a question every
morning so there is always something to write down, and a small mission that gives him a reason to
take the picture — and files it with the reason, the date it happened and the child's exact age, on a
timeline the kid inherits. The mission of the product, in one line from its own listing: *"Every
morning, one question about your kid and one small mission. Answer it, capture it, or just do it — it
lands on a timeline they'll inherit."*

## Status (Sep 7, 2026)

- **Live on the App Store**: https://apps.apple.com/us/app/pocketchronicle-app/id6800155810
  Listing name "PocketChronicle.App", subtitle "One prompt a day, kept forever", category Lifestyle,
  rated 4+, iPhone. Free download; Monthly Membership $5.99, Annual Membership $59.99 (in-app).

  *Those two product names are read off the **public App Store product page**, which is the
  storefront a reader can check, so they are the user-facing display names by definition. App Store
  Connect's own list shows "Membership Annual" instead — that is the internal **reference** name, and
  the difference is the thing `decisions.md` D5a has wrong. D5a calls both strings "display names"
  and then says "neither is user-facing"; both cannot be true, and `asc-verification-2026-09-05.md`
  rows 4b/4c call them reference names. **The report is right and the store page proves it**: Apple
  renders the display name on the product page and on the purchase sheet alike, so what is printed
  above is what a parent sees. Quote it safely — and if a writer needs only the money, give them
  $5.99 a month or $59.99 a year and skip the names, which is all they usually want.*
- **The first 14 days are full access, no card, nothing to cancel.** After that the daily question
  stays free forever and everything that needs storage — photos, video, voice — is part of
  membership. Source: `api/src/rascal/constants.py` `FREE_SLOTS = ("question",)`; the owner's rule
  on storage (Sep 7, 2026).
- Requires iOS 18.6 or later. On-device transcription needs iOS 26.
- **Reviewer offer:** lifetime access for any writer who likes it and will use it — issued as an
  entitlement grant with no practical end date (see *Reviewer access* below).

## What it does — verified

**The daily loop — two prompts a day.** One is always a question ("What did they say this week
that you want to remember exactly?", "Describe their laugh.", "What word do they mispronounce that
you don't want to correct?"). The other is a mission: a photo, a video, their voice, or something to
do together ("Get on the floor for ten minutes. That's the whole mission."). Weekends add a second
mission, and members also get a weekly mission, a monthly measurement, and letters sealed until an
age you choose — say "two prompts a day" in a pitch and leave the extras for the site. 133 prompts,
all published on the website. Source: `api/src/rascal/services/scheduler.py` (weekday rotation),
`api/seeds/prompts.yaml`.

**Four ways to answer, one tap from the card.** Photo or video; voice; a written sentence; or "did
it" — a complete entry with nothing to upload. Source: `ios/Rascal/Rascal/Composer/`.
*Precision that matters for press:* the **daily question is answered by typing** (the composer opens
on a text field). **Voice recording is how you answer a voice mission** ("Record them telling you a
story. Any story. Don't correct a single word.") **or a freeform entry from the + button** — and a
voice mission opens straight onto the recorder, no setup screen. Do not write "answer the daily
question by voice." Source: `ComposerView.swift` switches on the prompt's completion mode
(text → text field; media → capture choices; did-it → one tap).
*Quotable did-it mission:* "Get on the floor for ten minutes. That's the whole mission."
(`api/seeds/prompts.yaml`). Missions are part of Membership; frame quotes that way.

**Voice is transcribed on the phone.** Recording uses Apple's on-device `SpeechAnalyzer` (iOS 26).
The words are written back to the archive so they are searchable; the audio is never sent to a
transcription service. On an iPhone without the on-device model the recording still saves, without a
transcript. Source: `ios/Rascal/Rascal/Media/SpeechTranscription.swift`.
*Recording length:* **ten minutes, and it is safe to quote.** ~~The marketing site said two minutes;
do not quote a number until the owner picks one.~~ The site was corrected and deployed Sep 8, 2026 and
now says ten minutes too, so the app, the site and this kit agree.

**Fill in the past.** The composer's date control backdates any entry to any day — years ago if you
like — and *Look back* walks month by month through photos already on the phone to find months worth
writing about (photo scanning happens on the phone). A note about 2023 lands in 2023, with the age
the child was then. Source: `ios/Rascal/Rascal/Composer/` (date pill), `ios/Rascal/Rascal/Backfill/`.

**Every entry carries the child's exact age.** Computed from when it *happened*, not when it was
uploaded — backdating is a first-class flow, so a photo from 2019 imported tonight lands in 2019.
Source: `docs/api-contract.md` (`occurred_at` vs `created_at`; `child_age_months`).

**Search across everything**, including what was said out loud (titles, bodies, captions,
transcripts). Source: migration `0004_full_text_search`, `GET /entries?q=`.

**Timeline, filters, Moments.** The archive grouped by day, filterable by Photos / Video / Voice /
Written / Sealed; "Moments" resurfaces this day in earlier years.

**Sealed letters.** Write to the child now; it opens at the age you choose (e.g. 18). In an export,
letters are included in the clear — an export you cannot read is not a backup.

**Export, one tap, free on every tier.** Settings → *Export the archive* → a zip with every entry,
photo and recording in folders by date, plus an `index.html` viewer that opens offline from a
double-click. Formats: JPEG, MP4, M4A, plain text, HTML. Date-scoped exports too. Source:
`GET /children/{id}/export`, `ios/Rascal/Rascal/Settings/ArchiveExport.swift`.

**One notification a day, at most.** At a time you pick, off whenever you want. The server owns the
schedule; nothing on the phone nags. Source: `ios/CLAUDE.md` push rules.

**Household, not per child.** Multiple children under one account; invite the other parent to write
into the same archive; one membership covers all of it.

**Also:** a Lock Screen / Home Screen widget; a Share extension to file a photo from Photos without
opening the app; Sign in with Apple (primary), Google, or an email link added from Settings. No
Facebook login.

## Privacy and business model — verified

- **Native SwiftUI. Zero third-party dependencies.** SwiftUI, SwiftData and URLSession only — no SPM
  packages, no CocoaPods, no vendored SDKs — therefore no analytics SDK, no ad SDK, no tracker in the
  binary. Source: `ios/CLAUDE.md` rule 4 (83 files under `ios/Rascal/Rascal` import SwiftUI); `grep` of
  the iOS tree for Firebase/Amplitude/Mixpanel/AdSupport/ATTracking returns nothing.
- **No ads on any tier, including free. No data sale. Not used to train anything.**
- **Private by default.** No feed, no likes, no discovery, no follower count. Only the people you
  invite can see the archive.
- **Nothing you write is ever locked behind payment.** If you stop paying you drop to the free tier;
  the whole archive stays readable, searchable and exportable. Membership buys more of the day, never
  access to your own archive.
- **Deletion is real.** Account deletion waits seven days, then hard-deletes; sign back in to cancel.
- **Sign in with Apple** is a credential, not the identity model — the account is not tied to Apple.

**What NOT to claim.** The app is *not* "local-first" or "local-only": entries sync to Pocket
Chronicle's server so a second parent, a new phone, the widget and the export all work. What is on
the device: the voice-to-text model, the SwiftData cache, and no trackers. Say "private", "no ads",
"on-device transcription", "full export" — not "local-first".

## Free tier vs Membership

**The first 14 days: everything, free, no card.** Then:

| | Free (after the 14 days) | Membership |
|---|---|---|
| The daily question | Every day, forever | Every day, forever |
| The daily mission (photo, video, voice, or activity) | — | Every day |
| Photos, video, voice notes — anything that needs storage | — | Included, no limit |
| Weekly mission, monthly measurement, sealed letters | — | Included |
| The second parent on the same archive | — | Included |
| Everything already in the archive | Yours: readable, searchable, exportable | Yours |
| Search and full export | Always | Always |
| Ads | None | None |
| Price | $0 | $5.99/month or $59.99/year, one membership per household |

*~~The marketing site's pricing page still lists "100 photographs, lifetime" and "voice notes,
unlimited" on the free tier; do not quote it.~~ **Fixed and deployed Sep 8, 2026.** The site's free
column now reads an em dash for photographs, video and voice notes, and the site and the app agree.
Verified on the live page rather than the branch.*

*The gate is not merely written down, it is **enforcing in production**: `POST /v1/media/upload-url`
answers `402 subscription_required` unless the household is entitled, which
`rascal-api.fly.dev/openapi.json` documents in its own words. A household inside its fourteen days
passes; a free one does not. **Reads are untouched** — download, export, search and sync all work on
the free tier, so an archive already captured stays readable forever. That is the sentence to give a
writer who asks what happens to their photographs when they stop paying.*

## Design and tone — the rules the product is built under

- No streaks, no badges, no guilt copy, no red urgency states, no countdowns. A missed day is not a
  failure and the app never says it was.
- Never pure black or pure white. Cream canvas `#FDFAF4`, navy-charcoal ink `#23253C`. Terracotta
  for missions and primary actions, periwinkle for questions and voice, sage for did-it.
- Prompts never assume a child's gender; the app supports he/him, she/her and they/them, and the
  prompt library is written with pronoun tokens.
- The word "baby" appears nowhere. The subject is a child.

## Voice for anything written on the product's behalf

Plain, warm, specific, unhurried. Short declarative sentences. No exclamation marks. No
"revolutionize", "effortlessly", "magical", "unlock", "upgrade", "premium". No "before it's too
late", no "don't let these moments slip away" — the product exists to remove that guilt, not
manufacture it. **No invented testimonials, ratings or user numbers: the app went live on the App
Store this month.** "Lifetime access" is the right phrase for the reviewer offer; "join"/"member"
for everyone else. One test for every sentence: would it be embarrassing to read in 2040, in the
archive it is selling?

## Reviewer access — how the "free full access" offer actually works

The admin console (Today tab → *Grants — entitle a household without a payment*) issues an
**entitlement grant**: pick the account, pick the last day the grant covers, issue. The household
reads as fully entitled without touching Apple's `tier`. For a lifetime reviewer account, set the
date far out (e.g. 2099). Source: `docs/runbook-admin-console.md` §3b, phase 121. The writer only
has to download the app from the App Store and tell us the email they signed up with.

## Outlet status found during research (Sep 7, 2026)

- **iMore stopped publishing on Sep 25, 2024.** The site is an archive. Its Apple coverage moved to
  TechRadar and Tom's Guide (Future plc). The pitch file for iMore is addressed to TechRadar instead.
- **AppAdvice shut down on Jan 23, 2026** and the domain no longer resolves. Do not send.
- Several published tips addresses could not be verified on the outlets' own pages
  (tips@macstories.net, df@daringfireball.net, submissions@uncrate.com). Each pitch file names the
  route that was verified instead.

