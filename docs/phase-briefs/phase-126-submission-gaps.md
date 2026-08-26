# Phase 126 — Submission gaps: Settings legal links, export audit, App Privacy derivation

> **Allocation.** Number assigned Aug 25, 2026 by the owner and **measured, not inferred**:
> `phase-queue.md` offered 126 after 124 and 125 took the two numbers before it. Lane: **iOS**,
> plus two report files. Rides `ios/phase-124-app-review-compliance` with 124 and 125, by the
> owner's *"I have more for this PR"*.
>
> **Two things in the brief below are already known to be false, and are flagged here rather than
> discovered by whoever runs it.** Neither is edited out — the brief is the owner's text.
>
> 1. **Preflight gate 1 fails as written.** It says to stop if the paywall compliance phase is
>    mid-flight. Phase **124 is open on this very branch**, so a literal run halts at the first
>    gate. The gate's actual concern is that both phases touch Settings and must not race; sharing
>    one branch and one PR is the owner's answer to that, so the gate is satisfied in substance and
>    fails only on its wording.
> 2. **`Legal.swift` does not exist and should not be created.** Part 3 says to reuse it from the
>    paywall phase and to stop if it is absent. Phase 124's preflight
>    (`docs/reports/phase-124-preflight.md` §5.2) found that the URLs already have a home —
>    `LegalLinks` at `ios/Rascal/Rascal/Subscription/PaywallSheet.swift:608-624`, reading
>    `TERMS_URL` and `PRIVACY_URL` out of the Info.plist, with a `url.host()` guard that a test
>    pins. **Read `Legal.termsOfUse` / `Legal.privacyPolicy` below as `LegalLinks.terms` /
>    `LegalLinks.privacy`**, which are `URL?` rather than force-unwrapped constants, and which are
>    `nil` in every build today because `Config.xcconfig` supplies neither value. That is an owner
>    errand, filed at `docs/design/design-conformance-110.md` §7.4.
>
> The brief below is the owner's text, unedited apart from the number in this heading.

Lane B (iOS) plus an audit that produces a document, not code. Blocks App Store submission.

This phase is **audit first**. Two of the four items are "find out what is true," and the
answers change what gets built. Do the audit, report, then build only Part 3.

---

## Preflight gates

Any failed check stops the run. Produce a report, change nothing.

1. Read `roadmap-status.md`. Confirm the paywall compliance phase has landed or is not
   mid-flight. If it is in flight, stop — both phases touch Settings.
2. Read `decisions.md` for the free-tier definition and the lapse/deletion policy. These
   are the source of truth for what export must cover.
3. Confirm the phase number in this filename is assigned. If it is still `XX`, stop.
4. Report the Settings view path and the paywall view path before editing anything.

---

## Part 1 — Export audit (report only, no code)

The paywall states, under *What stays free, always*: "Search, and a full export of the
whole archive." That claim is live in front of users today, and the rewritten `/privacy`
page will repeat it. Establish whether it is true.

Answer each, with file and line references:

1. Does an export path exist at all — API route, iOS entry point, or neither?
2. If it exists, what does it produce? Text only, or media as well? What format?
3. Does it cover entries the free tier created *and* entries created while subscribed but
   now behind a paywall? A partial export would make the paywall claim false.
4. Does it include the originating prompt attached to each entry? An export without the
   prompt is not an export of this product — the prompt is the artifact.
5. Does it respect `occurred_at` versus `created_at` correctly, or does it flatten them?
6. Is it reachable from the UI, or only via API?

Do not build export in this phase. Report the gap and its size.

**If export does not exist:** say so at the top of the report in one sentence. Travis has
a live paywall making a claim the product does not honour, and that decision belongs to
him — either build it, or change the paywall copy.

---

## Part 2 — App Privacy derivation (report only, no code)

Apple's App Privacy labels must match what the app actually collects. They cannot be
filled in from memory. Walk the code and produce `app-privacy-labels.md` — a committable
file Travis transcribes into App Store Connect by hand.

For every data type the app collects, record:

- The Apple data category it maps to
- Whether it is linked to the user's identity
- Whether it is used for tracking (it should not be — verify, do not assume)
- The purpose, in Apple's taxonomy
- The file and line where collection happens

Cover at minimum, and flag anything else found:

- Sign in with Apple identity, including Private Relay addresses
- Photos, video, audio, and free text entered as entries
- The monthly measurement data — this is health-adjacent and needs a deliberate mapping
- Transcripts, captions and tags produced on device and persisted server-side
- Any crash, diagnostic or performance data, including anything a dependency collects
  without the app asking

Two specific things to verify rather than assume:

- **Third-party SDKs.** Enumerate every dependency and state whether each collects
  anything. A single analytics SDK pulled in transitively invalidates the "no tracking"
  position on the marketing site.
- **Data about a person who is not the user.** The archive's subject is a child who has no
  account. Apple's taxonomy has no clean category for this. Flag it explicitly in the
  report rather than silently mapping it to something convenient; it needs a human
  decision and probably an attorney's read.

---

## Part 3 — Settings legal links and Restore (build)

The only code in this phase.

Add to Settings, in a section titled `About`:

- `Terms of Use` → opens `Legal.termsOfUse` in `SFSafariViewController`
- `Privacy Policy` → opens `Legal.privacyPolicy` in `SFSafariViewController`
- `Restore Purchases` → the same action added to the paywall, reusing that
  implementation rather than duplicating it

Reuse `Legal.swift` from the paywall compliance phase. If it does not exist yet, stop —
this phase depends on it.

Restore behaviour in Settings is identical to the paywall, with one difference: on success
with an entitlement found, do not dismiss anything. Show a quiet confirmation and leave the
user in Settings.

Copy rules from `CLAUDE.md` apply. No urgency, no guilt, no "Don't lose access."

---

## Break-tests

1. Settings renders all three rows.
2. Both legal URLs are non-nil and open in-app, not via external Safari.
3. Restore in Settings calls the same underlying implementation as the paywall — assert
   there is one implementation, not two.
4. Restore from Settings does not dismiss or navigate away on success.
5. No code path in the diff sets entitlement state on the device.

If an assertion and the implementation disagree, assume the assertion is right. Stop and
report both sides rather than editing the test.

---

## Adversarial re-read

Answer in the PR body:

- Is the restore logic genuinely shared, or copy-pasted with small differences? Quote the
  lines.
- Did the export audit make any claim you inferred rather than read? Mark each one.
- Does the App Privacy report claim "not collected" anywhere you did not actually check a
  dependency's behaviour?
- Did anything outside Settings and the two new report files change?

---

## PR requirements

- One PR. Part 3 code, plus `export-audit.md` and `app-privacy-labels.md`.
- Rank the three things you are least confident about, most doubtful first.
- State what you verified by running versus by reading.

---

## Out of scope — do not do these

- Building export.
- Changing paywall copy, even if the export audit shows the claim is false. That is
  Travis's call.
- Account deletion (Guideline 5.1.1(v)). Separate phase.
- Entering anything into App Store Connect. The labels file is for a human to transcribe.

---

## Not in this prompt — manual, for Travis

**MX records for `hello@getvellumapp.com`.** Both legal pages and the App Store support
contact point there, and the domain currently has no mail routing. A reviewer may test it.
This is GoDaddy DNS plus a Resend inbound or forwarding setup — ten minutes, not a phase.
