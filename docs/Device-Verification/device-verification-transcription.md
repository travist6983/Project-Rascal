# Transcription — device verification

~~**Nothing in this feature has ever run.**~~ — **corrected Aug 17, 2026. It has run once, and
this sentence was the only thing keeping phase 16 shut.**

> **Owner, Aug 16, 2026:** `SpeechAnalyzer` produced a real transcription on a real device, on a
> build from that day, and the output was accurate enough to capture his son's actual
> pronunciation of words.
>
> **Owner-confirmed retrospectively, not agent-observed.** Nobody ran this checklist; this is one
> reported observation, written down where the gate reads it.

**No box below is ticked and the count is still 0 of 45**, deliberately. That single observation
covers part of one of §0's five boxes and none of the other four — it says nothing about three
recordings, about reading a transcript back against its audio, about whether names survive, or
about whether it invents plausible sentences where he mumbled. **§0 still needs running**, and it
says itself that it is the one measurement in this project that cannot be re-derived later,
because the recordings change as he does. A ticked §0 would stop anybody running it.

What the correction unblocks is **phase 16**, whose preflight read the struck sentence above and
hard-stopped — correctly, on input that had stopped being true.

**The rest of this file is unchanged and remains true:** the
test suite proves the queue, the writeback, the retry, the sync-conflict rule, and the two display
surfaces, and every one of those assertions runs against a stub transcriber. `SpeechAnalyzer` is
iOS 26 and the app deploys to 18.6, `isAvailable` is false on every simulator, and the model assets
are a several-hundred-megabyte download no CI runner has. So the seam has been exercised
exhaustively and **the thing behind the seam has been exercised zero times.**

Everything below is therefore about the half no test can reach. Run it on a real phone on
**iOS 26 or later** — on anything older the correct outcome is that nothing happens at all, and
§1 checks exactly that.

Run against a build pointed at a real API — `API_HOST` on the LAN, or a deployed one once section
3 of `docs/blocked.md` closes. **Sign the build**; an unsigned one cannot write to the keychain,
every request after sign-in comes back `401`, and it looks like an auth bug.

Do the audio checklist from PR #22 first. This one needs recordings to work on, and a recording
path that is itself unverified would make every failure here ambiguous.

Tick each line or write down what happened instead. A line that "seemed fine" is not ticked.

---

## 0a. Upgrade the build in place, before anything else

**Do this first, and do it before you delete anything.** This phase adds five properties to the
`Media` `@Model` — `transcriptState`, `transcriptAttemptCount`, `transcriptNextAttemptAt`,
`transcriptFailure`, `transcriptLocaleIdentifier`. Every one carries a declaration default or is
optional, which is the rule in `ios/CLAUDE.md`, and **nothing in the suite or in CI can prove it
worked.** Every test uses `isStoredInMemoryOnly: true`; `StoreMigrationTests` exercises the
file-backed path but writes and reads the *same* schema, so it cannot see a migration from the
previous build's store. A fresh install also starts from nothing and proves nothing.

The failure mode is not subtle: the store refuses to open and the app crashes on **every** launch
with no way back in. It has happened once already, to `bytesSent`.

- [ ] Install this build **over** the existing one — `xcrun simctl install` on a device that
      already has the previous build, or the equivalent over TestFlight. **Do not uninstall
      first.**
- [ ] Launch. It opens, and the timeline still has the entries it had before.
- [ ] Check `Library/Application Support/` for the app: there must be **no**
      `unreadable-store-*` folder. One means migration failed and the store was quarantined —
      the app recovered, but every unsynced local write in it is stranded.

Only once this passes is the rest of the page worth running.

## 0. The one that matters most, and no test can tell you

**Transcription quality on a four-year-old's speech is the open question of this entire phase.**
Apple's model is tuned for adult dictation. A four-year-old is quiet, fast, ungrammatical,
inconsistent in articulation, and frequently talking with a mouth full of something. It may be
excellent. It may be unusable. Nobody knows, and no amount of unit testing will find out.

So before anything else, and while you still have the energy to judge it fairly:

- [ ] Record **three ordinary voice notes** of him — not test phrases, not "say hello to the
      phone". A story, an explanation of something, and one at the noisy end of the day.
- [ ] Let them transcribe, then read each one **against the recording**, not from memory.
- [ ] Write down, per recording: roughly what fraction of words are right, and — separately —
      **whether the transcript is worth keeping at all.** These are different questions. A
      transcript at 60% accuracy may still be perfectly searchable, which is what it is for.
- [ ] Note specifically whether **names** survive. His name, siblings, pets, invented words. A
      transcript that loses every proper noun is a transcript that fails the one job the roadmap
      wants it for — finding a moment in 2040.
- [ ] Note whether it invents plausible sentences where he mumbled. Confident wrong text is
      worse in a permanent archive than a gap, and if it does this a lot, that is a design
      finding rather than a bug: it would argue for storing a confidence signal, which is a
      schema change and a separate phase.

**Record the answer somewhere durable even if it is "it's fine".** This is the only measurement
in the project that cannot be re-derived by running something later — the recordings change as
he does.

## 1. A phone that cannot do this

The silent-degradation rule, which is the one that protects everyone else's phone.

- [ ] On a device running **iOS 18–25**, or with the speech model not installed: open a voice
      entry. It renders exactly as it did before this build — player, duration, no transcript
      section, **no placeholder, no "pending" spinner, no error**.
- [ ] The timeline card for the same entry shows the periwinkle waveform band and its duration
      and nothing else new.
- [ ] Settings → the sync card shows **no** "Transcribe backlog" row at all if nothing is
      waiting, and if one is shown, tapping it reports the count as *couldn't do* rather than as
      failed.
- [ ] Nothing anywhere says the word "unavailable" to the parent.

## 2. A new recording

The automatic path. Opportunistic, and it must never be in the way.

- [ ] Record a voice note through the composer and save it.
- [ ] **Watch the composer close immediately.** Nothing waits on transcription — not the save,
      not the sheet dismissal, not the Today board updating.
- [ ] Background the app, come back. Open the entry. The transcript is there, set as readable
      body text under a **Transcript** label — 16pt, not monospace, not a quoted block.
- [ ] Go to Timeline. The card shows the waveform band **and the first line of the transcript**
      in italic underneath, unless you also wrote a note — in which case your note wins and the
      transcript stays on the detail screen.
- [ ] Confirm the phone did not get noticeably warm doing it. A ten-minute recording is the
      case to try if a short one is imperceptible.

## 3. It actually reached the server

The whole point of rule 7 — the phone is an inference worker and its output has to be durable.

- [ ] After a transcript appears, confirm the server has it:
      `curl -s "$API/v1/entries/<entry-id>" -H "Authorization: Bearer $TOKEN" | jq '.media[].transcript'`
- [ ] **Delete and reinstall the app.** Sign in, open the same entry. The transcript is still
      there — which proves it came back from the server rather than from this device's cache.
      *This is the single most important check on this page after §0.*
- [ ] Search for a distinctive word from the transcript (see §5). The entry comes back.

## 4. It survives being offline, and being interrupted

- [ ] **Airplane mode on.** Record a voice note and save it. Nothing errors.
- [ ] Confirm the entry appears on the timeline with a quiet **Saving** chip and no transcript.
- [ ] Turn the radio back on, foreground the app. The upload completes, then the transcript
      appears — in that order. It must not attempt to transcribe before the upload lands.
- [ ] **Force quit mid-transcription** (record something long, then swipe the app away a second
      or two after it saves). Relaunch. The transcription resumes and completes; it does not
      vanish and it does not start a duplicate.
- [ ] Put the phone in **Low Power Mode** and record another. Note what happens — this is
      unverified behaviour and worth writing down either way.

## 5. Search

Built so this feature is observable at all. Deliberately minimal — if you find yourself wanting
filters, history, or highlighting, that is a note for later and not a bug.

- [ ] Timeline → tap the **magnifier** in the header. The field appears with the cursor already
      in it, and the filter chips are hidden while it is open.
- [ ] Type a word slowly. Results arrive after you stop typing, not per keystroke.
- [ ] Type a word that is **only** in a transcript — not in any title or body. The entry comes
      back, and the card shows **the matching sentence of the transcript** so it is obvious why.
- [ ] Type something the archive does not contain. One quiet line, no illustration, no
      suggestions.
- [ ] Scroll a query with many results past the first page and confirm more load, without
      repeats.
- [ ] Tap **Cancel**. The timeline returns with its filter chips.
- [ ] Open a search result and come back to the results. Nothing has been lost.

**Scroll position across search is not promised, and I do not know what it does.** Opening search
swaps the list's contents for the results and Cancel swaps them back; where that leaves the offset
is SwiftUI's decision, not one this code makes. Opening search from **All** at least does not
rebuild the list — the `@Query` predicate is identical — so that is the case most likely to behave.
Note what actually happens from All and from a filter chip; if it lands somewhere jarring, that is
worth a small fix rather than a shrug.

**Known limitation worth confirming rather than reporting:** a result that matched on a
transcript written by *another* device will not show the matching line, because `GET /entries`
does not carry transcripts on the wire and this phone has not cached one. It should show an
ordinary card, not an empty one.

## 6. The backlog

- [ ] Settings → the sync card. The **Transcribe backlog** row states a count that matches the
      number of voice entries with no transcript. It is absent entirely if there are none.
- [ ] Tap it. Progress reads **n of m** and moves.
- [ ] **Leave the Settings tab while it runs**, then come back. It is still going.
- [ ] Tap **Stop** partway. It stops within a recording or so, and reports what it managed.
- [ ] Tap it again. It **resumes** — the count is lower than it was, not back at the start.
- [ ] Let a run finish. The summary names transcribed, couldn't-do, and didn't-finish
      separately.
- [ ] Watch the battery percentage across a run of twenty or more. Write down the drop. This is
      the number that decides whether the backlog stays manual forever or could ever be
      automatic while charging.
- [ ] **On cellular, off Wi-Fi**, run the backlog against entries recorded on *another* device
      (or after a fresh install, where nothing is staged locally). Those rows must **not**
      download: they should come back as didn't-finish, and the row's reason should read
      *"Waiting for Wi-Fi — this one is only on the server."* Confirm no meaningful cellular
      data was used, in Settings → Cellular.
- [ ] Back on Wi-Fi, run it again. The same rows now complete.
- [ ] **Also on cellular**, record something new and let it transcribe. This one *must* work —
      its audio is already on the phone and nothing is fetched. If it is also deferred, the
      staged-original path is not being taken and that is a bug.

## 7. Locale

- [ ] Set the phone's language to one with **no installed speech model** and record something in
      English. Confirm the transcript is still English and still sensible — it should fall back
      to `en-US` rather than transcribing English with the wrong model.
- [ ] Set the phone to a language that **does** have a model and confirm it uses that one.
- [ ] Set it back.

---

## What to send back

Whatever you write down for §0, verbatim. Then anything that failed, plus:

- Battery drop across a backlog run of twenty (§6).
- Whether names survived (§0), which is the finding most likely to change the design.
- Whether the reinstall check in §3 passed. If it did not, the transcript is not durable and
  that is a stop-everything result rather than a bug report.
