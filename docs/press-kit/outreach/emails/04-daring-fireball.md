# Daring Fireball — pitch

**Send to:** comments@daringfireball.net — the contact page (https://daringfireball.net/contact/) spells it out as "comments", followed by the at symbol, followed by "daringfireball.net". The given df@daringfireball.net does NOT appear on the contact page and is unverified. Alternates Gruber lists: Signal gruber.44 ("I very much welcome you to contact me on Signal") and Mastodon @gruber@mastodon.social ("I really do read all my Mastodon mentions"). He warns he is "a lousy correspondent — where by 'at times' I mean 'most of the time'."

**Fact-check verdict:** fix (corrections are already applied below) · body 167 words

---

## Email

**Subject:** Pocket Chronicle: a prompted childhood archive for iPhone, native, zero dependencies, no trackers

```text
I'm a dad who forgets to take pictures, and when I do remember, a year later I can't say what was happening or why I took it, so I built Pocket Chronicle, a prompted archive of a childhood for iPhone: two prompts a day, a question and a small mission to photograph, film, record or do, each filed with the reason, the date and my kid's exact age, on a timeline they inherit. It is native SwiftUI with zero third-party dependencies, so there is no analytics SDK, ad SDK or tracker in the binary, and voice is transcribed on the phone with iOS 26's SpeechAnalyzer, never by a transcription service. It is on the App Store at https://apps.apple.com/us/app/pocketchronicle-app/id6800155810 — the first 14 days are full access with no card and nothing to cancel, then the daily question stays free forever and anything that needs storage is part of a household membership at $5.99 a month or $59.99 a year.

Travis Terry
Founder, Pocket Chronicle
hello@pocketchronicle.app · https://pocketchronicle.app
```

## Follow-up (5–7 business days later, only if no reply)

**Subject:** Re: Pocket Chronicle: a prompted childhood archive for iPhone, native, zero dependencies, no trackers

```text
A short follow-up on Pocket Chronicle, the prompted childhood archive I sent last week, with one detail I left out: any entry can be backdated to any day, years ago, and Look back walks the camera roll month by month to find months you never wrote about, reading only dates and counts on the phone and uploading nothing. The app is at https://apps.apple.com/us/app/pocketchronicle-app/id6800155810 and the press kit, with the screenshots and a thirty-second video, is at https://pocketchronicle.app/press. If you like it and you'll actually use it, I'll give you lifetime access — just tell me the email you signed up with. If it isn't for you, no reply needed.

Travis Terry
Founder, Pocket Chronicle
hello@pocketchronicle.app · https://pocketchronicle.app
```

## Before you send

Send to comments@daringfireball.net, plain text, no attachments, no press-kit link in the first email (the body is exactly three sentences plus sign-off; the App Store link is the only link). Any weekday works; Gruber is in Philadelphia, so mid-morning ET is reasonable. Consider a parallel public Mastodon mention to @gruber@mastodon.social with the App Store link and one sentence, since he says he reads all mentions. The App Store link is live; no TestFlight steps. The follow-up (5–7 business days later, one only) carries the press-kit link, the lifetime-access offer and the App Store link, because the first email has no room for them. If he replies with the email he signed up with, issue the lifetime grant from the admin console (Today tab → Grants — entitle a household without a payment; set the last day far out, e.g. 2099). Body is 167 words including sign-off (wc -w). Given his stated response rate, treat no reply as normal and do not escalate.

**Personalization hook used:** None used in the body (three-sentence hard limit). Adjacent verified post for context: "Quiche Browser" 2026-03-20, https://daringfireball.net/linked/2026/03/20/quiche-browser, where Gruber praised an indie iPhone app for "craftsmanship" and a one-tap privacy control.

**Caveats:** df@daringfireball.net is not on the contact page; comments@ is. Because of the three-sentence limit, the first email omits the press kit and the lifetime-access offer by design; the four-sentence follow-up carries both. The first sentence is long by design so the founder's story and the product fit in one; it is one grammatical sentence. "The reason" means the prompt that caused the entry, per the fact sheet. "Anything that needs storage is part of a household membership" follows the owner's storage rule; the fact-sheet table also lists every daily mission, including the no-storage "did it" kind, as membership after the first 14 days. The App Store URL is followed by a space and an em dash so mail clients end the link at the space; check the rendered link once before sending. "iOS 26's SpeechAnalyzer": the app's minimum is iOS 18.6 and on an older iPhone the recording saves without a transcript. Look back in the follow-up is verified in ios/Rascal/Rascal/Backfill/BackfillScanner.swift (creation dates only; nothing uploads, transmits or logs asset content). Gruber almost never links to apps he has not used, so the realistic outcome is a link, if at all, after he has tried it. No recording-length number, user counts, ratings or testimonials; the website's stale free-tier numbers are not quoted.

## Research notes (what was verified, with URLs)

Submission route: no tips form; email to comments@daringfireball.net, Signal, or a public Mastodon mention. Contact page text: "if you don't use Mastodon (or Bluesky or Threads), or have remarks you'd prefer not to share in public, feel free to use email. No need to apologize — email is always welcome."

Recent adjacent Linked List posts (loaded):
1. "Quiche Browser" 2026-03-20 — https://daringfireball.net/linked/2026/03/20/quiche-browser — Gruber on indie developer Greg de J.'s iPhone-only browser: "It's just so thoughtful. So utterly modern in its appearance and features, but old-school in its hyperfocus on serving you, the user, through craftsmanship." Praises a one-tap per-site JS toggle.
2. "BitCam: The 1-Bit Camera App Turns 2.0" 2026-08-24 — listed on https://daringfireball.net/linked/2026/august — "a wonderful ode to the original Mac" with "extraordinary attention to detail."
3. "Apple Rethinks Plan to Merge 'Hide My Email' Domain Name With 'Sign In With Apple'" 2026-08-24 — same archive page.
Also on the August 2026 archive: "Finalist 4" (2026-08-30, indie planner app).

Tone: Gruber links to indie iOS apps he finds well-crafted and opinionated about privacy and design; he writes a paragraph or two of his own, so the pitch only needs to give him the thing and one reason it is well-made. He does not run press releases.

## Fact-checker's notes on this draft

- The follow-up contained a `[PRESS KIT LINK]` placeholder; the change list says follow-ups contain no brackets at all. Removed it at the time — and now that the kit is live at https://pocketchronicle.app/press, the real URL is folded into the App Store sentence, which is what the checker said to do once a URL existed; the follow-up keeps the Look back detail, the App Store link once, the lifetime offer and the easy no-reply, and stays at four sentences. The main email is unchanged: exactly three sentences before the sign-off, one link (App Store), dad story first person, first 14 days, no offer by design (there is no room in three sentences; the follow-up carries it).
