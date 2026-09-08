# 9to5Mac — pitch

**Send to:** michaelb@9to5mac.com — Michael Burkhardt, Associate Editor, runs the weekly Indie App Spotlight; the series archive page says "All submissions can be emailed to michaelb@9to5mac.com" (verified at https://9to5mac.com/guides/indie-app-spotlight/ and on his author page https://9to5mac.com/author/michaelb). The given tips@9to5mac.com is valid for general news tips (the contact page https://9to5mac.com/contact/ says "Email newsroom at tips [at] 9to5mac.com" and also lists tips+contact@9to5mac.com and an anonymous tips form), but for indie app coverage the Indie App Spotlight address is the better route.

**Fact-check verdict:** send (corrections are already applied below) · body 200 words

---

## Email

**Subject:** Indie App Spotlight submission: Pocket Chronicle, two prompts a day about your kid, now on the App Store

```text
Hi Michael,

I'm a dad and a solo developer, submitting Pocket Chronicle for Indie App Spotlight. I forget to take pictures, and when I do, a year later I can't say what was happening or why I took it. The camera roll remembers what my kid looked like, not what they were like.

Two prompts a day. One is a question: "Describe their laugh." The other is a mission: a photo, a video, their voice, or something to do together. Each is filed with the prompt, the date and my kid's exact age, on a timeline they inherit. Look back walks the camera roll, on the phone, for months I never wrote about; any entry backdates years.

Voice is transcribed on the phone, so what they said out loud is searchable.

The first 14 days are full access, no card, nothing to cancel. Then the question stays free forever; photos, video and voice are membership, $5.99/month or $59.99/year per household. If you like it and you'll actually use it, I'll give you lifetime access — just tell me the email you signed up with.

App Store: https://apps.apple.com/us/app/pocketchronicle-app/id6800155810
Press kit: https://pocketchronicle.app/press

Travis Terry
Founder, Pocket Chronicle
hello@pocketchronicle.app · https://pocketchronicle.app
```

## Follow-up (5–7 business days later, only if no reply)

**Subject:** Re: Indie App Spotlight submission: Pocket Chronicle, two prompts a day about your kid, now on the App Store

```text
Hi Michael,

Following up on Pocket Chronicle for Indie App Spotlight. One thing I didn't mention: export is one tap and free on every tier, a zip with every entry, photo and recording in folders by date, plus an index.html viewer that opens offline from a double-click. It's on the App Store at https://apps.apple.com/us/app/pocketchronicle-app/id6800155810 and the lifetime-access offer stands. If the series is full or it isn't the right fit, no reply needed.

Travis Terry
Founder, Pocket Chronicle
hello@pocketchronicle.app · https://pocketchronicle.app
```

## Before you send

Indie App Spotlight publishes Saturdays and Michael contributes Monday–Wednesday, so send Monday or Tuesday morning (9–11am ET) to michaelb@9to5mac.com for consideration that week. Plain text. The App Store link is live and in the body; no TestFlight steps. Link the press kit; the series uses screenshot galleries, so make sure the kit has 4–6 clean iPhone screenshots (cream canvas, no device frame required) and the app icon. Sending a tip to 9to5Mac constitutes permission to publish and syndicate. When Michael replies with the email he signed up with, issue the lifetime grant from the admin console (Today tab → Grants — entitle a household without a payment; set the last day far out, e.g. 2099). Body is 200 words including greeting and sign-off (wc -w). One follow-up after 5–7 business days, in the same thread.

**Personalization hook used:** The Indie App Spotlight series itself and its stated submission call (https://9to5mac.com/guides/indie-app-spotlight/): the email opens by submitting to the series by name, addressed to Michael Burkhardt. Most recent entry: "Indie App Spotlight: 'Laytr' ..." 2026-08-29, https://9to5mac.com/2026/08/29/indie-app-spotlight-laytr-is-a-one-stop-shop-for-logging-everything-you-want-to-find-later/

**Caveats:** The series says it covers apps that have "recently launched," which now applies: the app went live on the App Store this month. Michael is also an indie developer and may probe claims; the fact sheet says a grep of the iOS tree for Firebase/Amplitude/Mixpanel/AdSupport/ATTracking returns nothing, and zero third-party dependencies is verified in ios/CLAUDE.md. "Voice is transcribed on the phone" uses Apple's on-device SpeechAnalyzer, which needs iOS 26; on an older iPhone the recording saves without a transcript (the app's minimum is iOS 18.6). The daily question is typed; voice is how a voice mission or a freeform entry is answered. "Photos, video and voice are membership" is the owner's storage rule; the fact-sheet table also lists every daily mission, including the no-storage "did it" kind, as membership after the first 14 days. Look back verified in ios/Rascal/Rascal/Backfill/BackfillScanner.swift: only creation dates are read for the scan and nothing is uploaded. Pricing ($5.99/month, $59.99/year, one membership per household) is from the fact sheet; confirm App Store Connect matches. No recording-length number, user counts, ratings or testimonials; the website's stale free-tier numbers are not quoted. "Describe their laugh." is a library prompt, not a guaranteed same-day question.

## Research notes (what was verified, with URLs)

Submission route: Indie App Spotlight archive page (https://9to5mac.com/guides/indie-app-spotlight/) states: "Indie App Spotlight is a weekly 9to5Mac series run by Michael Burkhardt ... If you're an indie iOS app developer and have recently launched a new app, major update, or just have an app you think is interesting – let us know! All submissions can be emailed to michaelb@9to5mac.com." His author bio: Associate Editor, leads Apple news coverage Saturday and Sunday, contributes Monday–Wednesday, and is himself an indie iOS developer. General tips: tips@9to5mac.com per https://9to5mac.com/contact/ ("Submitting a tip constitutes permission to publish and syndicate").

Recent adjacent pieces (loaded):
1. "Indie App Spotlight: 'Laytr' is a one stop shop for logging everything you want to see later" by Michael Burkhardt, 2026-08-29 — https://9to5mac.com/2026/08/29/indie-app-spotlight-laytr-is-a-one-stop-shop-for-logging-everything-you-want-to-find-later/ — free iOS app, share-sheet capture, privacy-focused framing.
2. "Indie App Spotlight: 'KeyAlarm' turns your most important calendar events into alarms" 2026-09-05 — https://9to5mac.com/2026/09/05/indie-app-spotlight-keyalarm-calendar-events-into-alarms/ (listed on the series archive page; article itself not opened).
3. "iPadOS 26 adds new 'Journal' app, and I've been using it almost every day" by Ryan Christoffel, 2026-01-05 — https://9to5mac.com/2026/01/05/ipados-26-adds-new-journal-app-and-ive-been-using-it-almost-every-day/ — Apple Journal's suggestions as a way to start entries.

Format/tone: Spotlight pieces are short (roughly 400–600 words), plain, feature-led, run on Saturdays, with a screenshot gallery and an App Store link; they favor apps that are already downloadable. Pricing is always stated.

## Fact-checker's notes on this draft

- none
