# MacStories — pitch

**Send to:** voorhees@macstories.net (John Voorhees, Managing Editor; verified on https://www.macstories.net/about/, Cloudflare-obfuscated), with team@macstories.net in cc (verified on https://www.macstories.net/club/authors/macstories). The given tips@macstories.net is UNVERIFIED: it does not appear on the About page, the homepage, or the team page; the only place it surfaced was a third-party search snippet. viticci@macstories.net is also verified on the About page but Federico is a less natural fit for this pitch.

**Fact-check verdict:** send (corrections are already applied below) · body 199 words

---

## Email

**Subject:** Pocket Chronicle, now on the App Store: a prompted childhood archive, native SwiftUI, zero dependencies, on-device transcription

```text
Hi John,

I'm a dad who forgets to take pictures. When I do remember, a year later I can't say what was happening or why I took it. The camera roll remembers what my kid looked like, not what they were like.

Pocket Chronicle is my fix: two prompts a day. One is a question. The other is a mission: a photo, a video, their voice, or something to do together. Each is filed with the prompt, the date and their exact age, on a timeline they inherit. Look back walks the camera roll, on the phone, for months I never wrote about; any entry backdates years.

Voice is transcribed on the phone with iOS 26's SpeechAnalyzer, the API you went hands-on with after WWDC 2025. Native SwiftUI, zero third-party dependencies.

The first 14 days are full access, no card, nothing to cancel. Then the daily question stays free forever; photos, video and voice are membership, $5.99/month or $59.99/year. If you like it and you'll actually use it, I'll give you lifetime access — just tell me the email you signed up with.

App Store: https://apps.apple.com/us/app/pocketchronicle-app/id6800155810
Press kit: https://pocketchronicle.app/press

Travis Terry
Founder, Pocket Chronicle
hello@pocketchronicle.app · https://pocketchronicle.app
```

## Follow-up (5–7 business days later, only if no reply)

**Subject:** Re: Pocket Chronicle, now on the App Store: a prompted childhood archive, native SwiftUI, zero dependencies, on-device transcription

```text
Hi John,

A short follow-up on Pocket Chronicle, the prompted childhood archive I sent last week. One detail I left out: the prompt library is written with pronoun tokens, so the app supports he/him, she/her and they/them and no prompt ever assumes a child's gender. It's at https://apps.apple.com/us/app/pocketchronicle-app/id6800155810 and the lifetime-access offer stands. If it isn't a fit for MacStories, no reply needed.

Travis Terry
Founder, Pocket Chronicle
hello@pocketchronicle.app · https://pocketchronicle.app
```

## Before you send

Send Tuesday–Thursday, 8–10am US Eastern, to voorhees@macstories.net with team@macstories.net in cc. Plain text, no attachments; link the press kit and keep two or three screenshots in it for reference only (MacStories uses their own). The App Store link is live and in the body; there are no TestFlight steps. When John replies with the email he signed up with, issue the lifetime grant the same day from the admin console: Today tab → Grants — entitle a household without a payment → pick the account, set the last day far out (e.g. 2099), issue (docs/runbook-admin-console.md §3b). Body is 199 words including greeting and sign-off (wc -w; the em dash and the middle dot in the sign-off each count as a word). One follow-up only, 5–7 business days later, in the same thread.

**Personalization hook used:** "Hands-On: How Apple's New Speech APIs Outpace Whisper for Lightning-Fast Transcription" by John Voorhees, 2025-06-17 — https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/ — referenced in the email as "the API you went hands-on with after WWDC 2025."

**Caveats:** tips@macstories.net could not be verified on any macstories.net page; use voorhees@ and cc team@. "iOS 26's SpeechAnalyzer": the app requires iOS 18.6 or later, and on an iPhone without the on-device model the recording still saves without a transcript; be ready to say so if John asks. The daily question is answered by typing (the composer opens on a text field); the email never says the question is answered by voice. "Photos, video and voice are membership" follows the owner's storage rule in the fact sheet; the fact-sheet table also lists the daily mission itself, including the no-storage "did it" mission, as membership after the first 14 days, so if asked: only the daily question is free forever. The Look back sentence was checked against ios/Rascal/Rascal/Backfill/BackfillScanner.swift: the scan asks only for asset creation dates and the file states nothing uploads, transmits or logs asset content; individual photos are read only after the parent opens a month. Backdating is the composer's date control; age is computed from when the entry happened. No recording-length number, no user counts, ratings or testimonials, and the website's stale free-tier numbers are not quoted. Prices are from the fact sheet; confirm App Store Connect matches before sending. "Kid" is used in the founder's voice; the product's own copy says "child."

## Research notes (what was verified, with URLs)

Submission route: MacStories has no formal tips form or app-submission page. The About page (https://www.macstories.net/about/) lists the two editors' addresses (viticci@ and voorhees@macstories.net) and states editorial policy: "We focus on in-depth app reviews; we always use our own screenshots ... and only write about apps if we have personally tested them" and they have "never done and never will do paid reviews." So hands-on access matters more than press images. The Club team page carries team@macstories.net.

Recent adjacent pieces (all loaded):
1. "Hands-On: How Apple's New Speech APIs Outpace Whisper for Lightning-Fast Transcription" by John Voorhees, 2025-06-17 — https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/ — tests SpeechAnalyzer/SpeechTranscriber on-device; predicts it will replace Whisper as the default transcription model on Apple platforms. Direct hook for our on-device transcription.
2. "MacStories Selects 2025: Recognizing the Best Apps of the Year", 2025-12-16 — https://www.macstories.net/stories/macstories-selects-2025-recognizing-the-best-apps-of-the-year/ — celebrates indie developers and privacy-forward on-device design.
3. "Wading Back Into the Liquid Glass Pool: The MacStories OS 26 App Roundup Continued", 2025-11-21 — https://www.macstories.net/stories/wading-back-into-the-liquid-glass-pool-the-macstories-os-26-app-roundup-continued/ — nine indie apps, emphasis on on-device processing.

Right person: John Voorhees writes most 2026 app reviews on https://www.macstories.net/reviews/ (Big Walk, Aug 11 2026; Pastebot 3, Jul 21 2026; Book Beats, May 19 2026) and wrote the SpeechAnalyzer hands-on. Tone: long-form, personal, craft-focused, indie-friendly; no journaling or parenting app reviews found in 2026, so this would be a fresh category for them.

## Fact-checker's notes on this draft

- none
