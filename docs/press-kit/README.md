# Pocket Chronicle — press kit

Everything a writer needs, built Sep 7, 2026 from the app as it is in this tree (Debug build of
`ios/`, against a local API, on an iPhone 17 Pro simulator at 1206 × 2622). The app is **live on the
App Store**: https://apps.apple.com/us/app/pocketchronicle-app/id6800155810

**The kit is published at https://pocketchronicle.app/press**, built as a real page on the marketing site, and
every email in `outreach/emails/` already links it. `presskit-final/` is the same kit as a folder,
for anyone who would rather have files than a URL; `pocket-chronicle-press-kit.zip` beside it is that
folder zipped, and the site offers the same zip as a download.

| Folder | What is in it |
|---|---|
| `fact-sheet.md` | Every product claim, verified against the code, plus the claims **not** to make. Read first. |
| `icon/` | `pocket-chronicle-app-icon-1024.png` (App Store master, square, no alpha), a rounded-corner variant, 512 and 256 sizes, and the source SVG. |
| `screenshots/` | Six core screenshots (below) and `more/` with fifteen others. Raw device captures, 1206 × 2622, status bar set to 9:41, light mode. |
| `video/` | `pocket-chronicle-demo.mp4` — 29.8 s, 1080 × 1920, silent: the board, a voice prompt recorded live, the transcript, and a note filled in for 2023. Plus `raw/` with the untouched recordings. |
| `outreach/` | The target directory, one ready-to-send pitch per outlet with a follow-up, and `tracker.csv`. |

## The six core screenshots

| File | Shows | Why it is in the kit |
|---|---|---|
| `01-today-daily-prompts.png` | The Today board: the day's photo mission and the daily question, "Capture it" / "Write it" | The single best "what the app is" shot — two prompts a day |
| `02-timeline-archive.png` | The archive by day with the child's age on every day: a written entry, a voice entry with waveform, another written | Proves the archive and the age stamp |
| `03-voice-entry-transcript.png` | A voice entry open: waveform, 0:12, and the transcript underneath | Voice is transcribed and readable |
| `04-moments-on-this-day.png` | "On this day" — Sep 7 in 2025 and 2024 | The archive gives back |
| `05-voice-recording.png` | The recorder mid-recording, live waveform, 0:02 | The capture surface, in use |
| `06-timeline-filled-in-2023.png` | The Timeline scrolled to 2023: "7 September 2023 · 1y 2m", an entry written today and filed three years back | Fill in the past; the age is the age they were |

`more/` adds the full weekend board, the "Add to the archive" sheet (Photo / Camera / Voice / Write
/ Browse your camera roll), the composer for a typed question, the composer backdated to 2023, the
recorder idle and at review ("Have a listen before you keep it"), three onboarding steps (pronouns,
birthdate, "One note a day?"), the "Two weeks, everything open" trial screen, and Settings (archive,
household and membership card, "Export the archive"). The export shot is cropped below the status bar
because the list had scrolled under it.

## About the demo data

The archive in every capture belongs to **Wren, a fictional child (they/them, born July 3, 2022)**,
created through the app's own onboarding on a throwaway account (`press@rascal.local`) against a
local database. Every entry was written for the kit and posted through the public API — the same
calls the phone makes — except the two made on camera for the video (a voice recording and a
backdated note), which the app itself created. Voice audio is synthesized speech; transcripts were
written back through `PATCH /media/{id}/derived` exactly as the phone does after on-device
transcription, because the Simulator cannot run the speech model. No real family's data appears
anywhere. No child photos appear because there are none we have the right to publish; the timeline
shots lead with written and voice entries, which matches "not everything worth keeping is a
photograph".

## Three things to know before quoting the app

- **Two prompts a day.** One is always a question; the other is a mission — a photo, a video,
  their voice, or something to do together. The **daily question is answered by typing**; voice
  recording answers voice missions and freeform entries, and those recordings are transcribed on
  the phone.
- **The first 14 days are full access, no card.** After that the daily question is free forever and
  anything that needs storage (photos, video, voice) is part of membership at $5.99/month or
  $59.99/year. The marketing site's pricing page still says "100 photographs" and "unlimited voice
  notes" on the free tier — don't quote it; fix it.
- The recorder allows up to **ten minutes**; the marketing site says **two minutes** per voice note.
  Pick one before anyone asks.
