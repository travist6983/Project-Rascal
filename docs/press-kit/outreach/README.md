# Pocket Chronicle — media outreach directory and pitch guide

Fourteen targets, one ready-to-send email each, in `emails/`. Every email was written against
`../fact-sheet.md` (the verified product facts) and then fact-checked by a second pass; the
corrections are already applied. **Read `../fact-sheet.md` once before sending anything** — it names
the claims that must not be made ("local-first", a recording-length number, users or testimonials).

## Before you send — the checklist

1. **Press kit link — done.** The kit is live at **https://pocketchronicle.app/press** and every email already
   carries it. Nothing to upload, nothing to replace. Where the notes below still mention a
   `[PRESS KIT LINK]` placeholder, that is a record of the fact-check, not something left to do.
2. **The app is live.** Every email carries the App Store link once:
   https://apps.apple.com/us/app/pocketchronicle-app/id6800155810 — nothing to do here except make
   sure the listing still matches what the emails say (Monthly $5.99, Annual $59.99).
3. **Lifetime access for writers.** Each email offers it to anyone who likes the app and will use
   it. When a writer replies with the email they signed up with: admin console → Today tab →
   *Grants — entitle a household without a payment* → pick the account → set the last covered day far
   out (e.g. 2099) → *Issue grant*. Runbook: `docs/runbook-admin-console.md` §3b.
4. **Tracking.** `tracker.csv` has one row per target with the verified route and the pitch file.
   Fill `date_sent`; `follow_up_due` is 5–7 business days later. Each pitch file carries its
   follow-up email. Send one follow-up only.
5. **Follow-ups are ready as written** — 3–4 sentences, one new detail, the App Store link, an easy
   no. The only placeholder anywhere is `[PRESS KIT LINK]` (and `[EDITOR NAME]` in the AppAdvice
   template).

## What research changed about the target list

| Original target | Finding (Sep 7, 2026) | What to do |
|---|---|---|
| iMore (`news@imore.com`) | **Stopped publishing Sep 25, 2024.** Archive only. | The pitch file is rewritten for **TechRadar** (`news@techradar.com`), the Future plc sister site that absorbed its Apple coverage. |
| AppAdvice (`submission@appadvice.com`) | **Shut down Jan 23, 2026.** Domain no longer resolves. | Do not send. The draft is kept as a template for a live curated-list site (verify the route first). |
| MacStories (`tips@macstories.net`) | Address not on their site. | Send to **voorhees@macstories.net**, cc team@macstories.net. John Voorhees wrote the SpeechAnalyzer hands-on the pitch references. |
| 9to5Mac (`tips@9to5mac.com`) | Valid for news; the indie series has its own inbox. | Send to **michaelb@9to5mac.com** (Indie App Spotlight, publishes Saturdays). |
| Daring Fireball (`df@daringfireball.net`) | Not on his contact page. | **comments@daringfireball.net**. Three sentences, exactly. |
| Uncrate (`submissions@uncrate.com`) | Not on their site. | Use the **contact form** at uncrate.com/contact, subject "Submissions/Questions". |
| Cool Material (`info@`) | | **hello@coolmaterial.com** was the address found on-site. |
| Motherly | No press inbox. | **Submittable** for the essay (finished 700–900-word draft needed) plus hello@mother.ly for the pitch. Allow 3–4 weeks. |

The four Substack/blog targets resolve to: technosapiens.substack@gmail.com, the Tech Positive
Parenting contact form, management@workspaceforchildren.com, kathryn@kathrynwhatcher.com,
the Modern Parents Messy Kids contact form, and denaye@simplefamilies.com. Each pitch file
records where the address was found.

## The pitches

| # | Outlet | Angle the email leads with | File |
|---|---|---|---|
| 01 | MacStories | On-device SpeechAnalyzer transcription; native SwiftUI, zero dependencies; offline-readable export | `emails/01-macstories.md` |
| 02 | 9to5Mac | Indie App Spotlight submission; the daily prompt workflow | `emails/02-9to5mac.md` |
| 03 | TechRadar (was iMore) | iOS experience, no trackers, family utility | `emails/03-imore.md` |
| 04 | Daring Fireball | Three sentences: what it is, why it is well made, the link | `emails/04-daring-fireball.md` |
| 05 | AppAdvice (closed) | Template only | `emails/05-appadvice.md` |
| 06 | Uncrate | Design-forward, quiet alternative to feeds; under 100 words, form submission | `emails/06-uncrate.md` |
| 07 | Cool Material | A minimalist tool for one everyday task | `emails/07-cool-material.md` |
| 08 | Techno Sapiens | Anti-sharenting: private memory keeping, no feed; references her July post | `emails/08-techno-sapiens.md` |
| 09 | Tech Positive Parenting | Technology that serves the family; privacy-first archive | `emails/09-tech-positive-parenting.md` |
| 10 | The Workspace for Children | Unbusy parenting; the did-it entry; no streaks | `emails/10-the-workspace-for-children.md` |
| 11 | Parent Tech Built in the Margins | Founder to founder; mental load; fifteen-second prompts | `emails/11-parent-tech-built-in-the-margins.md` |
| 12 | Modern Parents Messy Kids | Realistic memory keeping without a scrapbook | `emails/12-modern-parents-messy-kids.md` |
| 13 | Simple Families | Digital decluttering: one prompt instead of 4,000 photos | `emails/13-simple-families.md` |
| 14 | Motherly | The piece: journaling milestones in thirty seconds a day | `emails/14-motherly.md` |

## What changed from the original templates

- **The founder's story leads.** Every email is written as a dad who forgets to take pictures and,
  a year later, can't say why he took the ones he did — the reason the product exists.
- **Two prompts a day**: a question, always, and a mission (photo, video, voice, or something to do).
  The daily question is answered by typing; voice recording answers voice missions and freeform
  entries, transcribed on the phone. The originals said the daily prompt was answered "via local
  voice-to-text"; that is not how the app works.
- **The first 14 days are full access, no card**; after that the question is free forever and
  anything that needs storage is membership. No "two-week trial", no App Store intro offer.
- **Live on the App Store**, with the link. No TestFlight, no "in review".
- **Lifetime access** for writers who like it and will use it.
- Dropped: "local-first", "local ZIP exports" (entries sync to the server so the second parent, a
  new phone and the export all work), any recording-length number, any user or testimonial claim.
