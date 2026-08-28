# Phases 124, 125 and 126 — submission compliance

**Not committed and no pull request opened.** This file is the PR body, written to disk so the
owner can use it when he decides to. The work is in the working tree.

---

## The copy change, before and after

The owner asked for these quoted in full. All of them are his words; none was authored here.

### Inside `MembershipCopy.swift`

| | Before | After |
|---|---|---|
| `freeLabel` | `What stays free, always` | `Yours either way` |
| `stayFree[0]` | `A question every day, forever` | `A new question every day, with no limit and no countdown.` |
| `stayFree[1]` | `Everything you've already written or captured` | `Everything you've already written and captured stays yours.` |
| `stayFree[2]` | `Search, and a full export of the whole archive` | `Search the whole archive, and export all of it whenever you want.` |
| `footnote` | `One membership covers the whole family — every child, both parents.` | `One price covers everyone in the house — every parent, every child.` |
| `renewalTerms` | *(did not exist)* | `Membership renews automatically until cancelled. Cancel any time in your Apple Account settings.` |

**The terminal full stops on the three `stayFree` lines are deliberate.** The originals were
fragments; the replacements are sentences.

**`freeLabel` is sentence case in source and stays that way.** The surface renders it uppercased by
text style, not by content. Committing an uppercased literal would put the casing decision in two
places.

### Outside `MembershipCopy.swift` — and there is more of it

The instruction was to *"confirm nothing outside MembershipCopy changed."* **That is not true of
this branch, and cannot be**, because the branch carries three phases rather than the copy revision
alone. Stated plainly rather than quietly narrowed. Four further owner-authored strings live in
`SubscriptionSection.swift` because that is where the Settings membership card is:

| | Before | After |
|---|---|---|
| Status row label | `Household` | `Your household` |
| Membership action row, title | `See the subscription` | `See what membership includes` |
| Membership action row, subtitle | `One price for the whole household — both parents, every child.` | `One price covers everyone in the house — every parent, every child.` |
| Restore row, subtitle | `Rarely needed — your subscription follows the household, not the phone.` | `If you've paid before and this phone doesn't know it yet.` |

**The restore row's *title* is unchanged.** App Review 3.1.2(c) wants that control present and
recognisable; renaming it is a rejection risk for no gain.

And one string authored **by the owner in this session**, from three candidates, because the surface
needed a sentence that did not exist:

- `SubscriptionModel.restoreFound` = `Found it. Your membership is active.`

`docs/design/free-tier-copy.md` forbids an agent writing a user-visible string on this surface. A
placeholder was written, **the rule was raised rather than quietly broken**, and the owner chose the
wording. It is recorded in that file as §7's fifth string.

### The footnote, and the one thing it puts out of step

The footnote was **not** in phase 125's list and was deliberately left alone under that phase's match
rule — it was reported as an inconsistency rather than fixed. The owner then asked for it, choosing
to reuse the §3.3 sentence he had already authored rather than write a sibling.

**`getvellumapp.com/terms` still reads *"One membership covers the household — every child, both
parents."*** Read in a browser on Aug 26, 2026. The marketing site is a different repository and a
different lane, so the app and the site now disagree on this sentence until somebody moves the site.

---

## Tests touched, and why

The owner's instruction: *"If any snapshot or string test asserts the old footnote, update the
assertion — this is an intentional copy change, and it is the one case where the assertion is not the
source of truth."*

**No test asserted the old footnote.** `grep -rn "One membership covers the whole family"
ios/Rascal/RascalTests/` was empty before this branch — which is exactly why a string the owner had
already objected to on a neighbouring row survived on the paywall. So nothing was *updated* for the
footnote; a test was **added**.

| File | What changed | Why |
|---|---|---|
| `SettingsMembershipTests.swift` | `theReassuranceIsTheApprovedBlock` — the four asserted values updated to the new free block | **This is the one case the owner named.** The test pins the copy by value; the copy intentionally changed. Six lines, values only, no assertion weakened or deleted. |
| `SettingsMembershipTests.swift` | One doc comment quoting `See the subscription` | Prose, not an assertion. |
| `MembershipTests.swift` | `noBannedWordInAnySurfaceSource` — added `Subscription/SubscriptionModel.swift` to its file list | **A real gap, not tidying.** Both sentences a restore leaves behind are authored in that file and were in no file the guard scanned. Break-tested by planting `Upgrade` in it. |
| `AppReviewRequirementsTests.swift` | One doc comment struck in place | It asserted `Config.xcconfig` defines neither legal key and that they "cannot render today". Both halves are now false. |
| `SubscriptionTests.swift` | **11 tests added, one corrected** | The restore-confirmation channel and its four transition guards. `aLateRestoreWithAFailedRefreshClaimsNothing` was **corrected** in round 4 — it asserted the pre-fix behaviour. | The restore-confirmation channel, the `.late`-found path, the failed-refresh path, and the lapse clear. |
| `SubmissionComplianceTests.swift` | **New file, 20 tests** | Phases 124/125/126 pinned. |

**Nothing else in the suite was touched, and no assertion was weakened to make anything pass.**

---

## What shipped, by phase

### 124 — guideline 3.1.2

The preflight found most of the brief had already shipped in phase 110. Three things were left:

1. **The renewal-terms disclosure**, below the plan rows and above *Become a member*, gated on
   `canOffer` so it appears exactly when the prices it qualifies do.
2. **`SFSafariViewController`** in place of two SwiftUI `Link`s, which handed a reviewer out to
   Safari mid-check. New shared `DesignSystem/SafariView.swift`; both the paywall and Settings
   present the same one.
3. **Dismiss on a successful restore**, via one pure `MembershipPresentation.dismissAfterRestore`.
   The decision lives in the caller, not in `restore()`, because Settings calls the same method and
   must *not* dismiss.

Plus a **scheme guard** beside the existing host guard: `ftp://example.com` has a host and survives
`url.host()`, and `SFSafariViewController` opens http and https and nothing else.

**`Legal.swift` was not created**, per the owner's constraint and the preflight's reasoning.
`LegalLinks` already reads both URLs from Info.plist and guards on `url.host()`; the brief's version
hardcodes and force-unwraps them, and would route around the guard
`AppReviewRequirementsTests.theHostGuardIsIntact` pins.

### 125 — the eight strings

All eight matched their `from` text exactly and in full, so the match rule triggered no stop. None
carried a pronoun token, in either direction. `free-tier-copy.md` updated in the same commit, with
every string marked owner-authored and approved.

**Four of them are shared with the paywall.** `freeLabel` and the three `stayFree` lines live in
`MembershipCopy` and render on both surfaces. Forking them would have created the second source of
truth the phase is trying to avoid, so they moved on both — which is §5's own decision to render one
approved block in two places.

### 126 — the submission gaps

- **Settings *About*** with Terms of Use and Privacy Policy, opening in-app.
- **`restoreConfirmation`** — a restore from Settings does not dismiss, so without a sentence the row
  spins and stops, which is indistinguishable from a failure.
- **Two report documents**: `phase-126-export-audit.md` and `phase-126-app-privacy-labels.md`.

**No second Restore control was added**, per the owner's constraint.
`SubscriptionSection.swift:63-75` has offered one since phase 37b.
`SubmissionComplianceTests.thereIsOneRestoreControlInSettings` pins that there is exactly one, in
either direction, and it enumerates `Settings/` off disk rather than checking a hardcoded pair.

---

## Verification

**Verified by running:** 1242 tests in 150 suites, green. Cold build with `DerivedData` deleted,
**zero warnings** in all four directories CI gates. Four consecutive full runs, no flakes. Paywall
rendered at default and at AX5 through the screenshot harness — the disclosure, both legal links and
the new free block all present, nothing truncated.

**Break-tested — twenty mutations, twenty confirmed red**, each reverted:

| # | Mutation | Test that went red |
|---|---|---|
| 1 | Drop `renewalTerms` from the price group | the paywall renders the renewal terms |
| 2 | Restore the SwiftUI `Link`s | legal links open in the app, not in Safari |
| 3 | Remove the `dismissAfterRestore` call | the paywall acts on the dismiss decision |
| 4 | Remove `aboutSection` from `content` | the About section is on the screen |
| 5 | Revert one owner string | the Membership card carries the owner's strings |
| 6 | Stop setting `restoreConfirmation` | a restore that finds a membership says so |
| 7 | Stop rendering it on the card | a restore from Settings leaves a sentence behind |
| 8 | Add a second Restore control | there is exactly one restore control in Settings |
| 9 | Plant `Upgrade` in `SubscriptionModel` | no banned word in any surface source |
| 10 | Delete both keys from `Config.xcconfig` | the configured legal URLs actually resolve |
| 11 | Break the `.late`-found branch | a restore whose window closed still says so |
| 12 | Remove the lapse clear | a membership that goes away takes its confirmation |
| 13 | Revert the footnote | the paywall footnote is the owner's sentence |
| 14 | Trust the stale household in the `.late` branch | a restore whose confirming read failed claims nothing |
| 15 | Reintroduce the Safari jump via `openURL` rather than `Link` | legal links open in the app, not in Safari |
| 16 | Remove the stale-notice clear | a membership that arrives after the window clears the notice |
| 17 | Stop `confirm()` clearing a stale notice | an approval after a fruitless restore clears the notice |
| 18 | Write "nothing arrived" unconditionally on a failed read | a restore whose confirming read failed claims nothing |
| 19 | Delete `restore()`'s prologue confirmation clear | a refused restore does not leave the last run's confirmation standing |
| 20 | Delete `load()`'s publish-site reconciliation | a load never publishes a household its own channels contradict |

**Verified by reading, not running:** every file/line citation in the two report documents, and the
claims in `blocked.md` §19 about which machine has which keys.

**Not verified:** nothing on a physical device; no App Store Connect product exists, so the paywall's
`.ready` state was exercised through the preview harness rather than a real storefront.

---

## Review

**Six adversarial rounds**, six independent lenses each, every finding independently refuted or
confirmed before being acted on. Every confirmed finding was fixed and then break-tested.

| Round | Raised | Confirmed | Distinct | What it caught |
|---|---|---|---|---|
| 1 | 25 | 11 | 11 | The legal URLs could go missing with nothing failing; a stale confirmation survived a lapse |
| 2 | 31 | 15 | 7 | **Two defects round 1's own fixes introduced**; the jump-out guard missed `openURL` |
| 3 | 38 | 18 | 8 | **Two stale quotations this diff itself created**; the `notice` mirror was never cleared |
| 4 | 9 | 9 | 6 | `confirm()` was an unguarded fourth writer; **round 3's fix created the inverse contradiction** |
| 5 | 3 | 2 | 2 | A test named for a line it did not cover, masked by a different clear |
| 6 | 1 | 1 | 1 | `load()` published a household its own channels could contradict |

**The pattern is the argument for iterating.** Rounds 1, 2, 3 and 4 each introduced at least one
defect that the next round caught, and round 6 — the round expected to come back empty — found the
last publish site that reconciled nothing. Reviewing once would have shipped every one of them.

**Round 6 also repeated round 5's lesson at my own expense.** The first test written for that fix
called `load()` fresh, was satisfied by the prologue clear, and **passed against a deliberately
broken model** — break-test 20 came back green. The uncovered case is a restore completing *inside*
load's await window, so the test now stages that interleaving with a one-shot `Gate` that parks the
injected read mid-flight. Break-test 20 is red against the staged version.

The findings that mattered most, in order:

- **Nothing failed when the legal URLs went missing.** Every test in the new suite greps source
  text, so all of them passed on a build with neither key — paywall renders no links, Settings drops
  the About section, submission rejected. That is exactly what `blocked.md` §19 has been open for
  since Aug 22. `theLegalURLsResolveInThisBuild` now resolves them through `Bundle.main`.
- **The restore state machine contradicted itself in four different ways**, found one at a time
  across rounds 2–4: a lapse left "your membership is active" standing; a late arrival left "nothing
  has arrived yet" under a subscribed row; `confirm()` was a fourth writer to `household` that
  neither transition guard could see; and the fix for announcing off a stale summary made a *failed*
  read write "nothing arrived" over a subscribed card. All four are now guarded and each has a test.
- **A test that was a false witness.** `aSecondRestoreClearsTheConfirmation` is named for
  `restore()`'s prologue clear and passes without it, because its second run happens to trip a
  different clear in `refreshHousehold()`. Break-test 19 proves it: deleting the prologue line turns
  exactly one test red, and it is the new one.

**Two process notes worth carrying forward.**

*A read-only review fleet running concurrently with a break-test reads a tree that is briefly
lying.* One round-3 recheck reported that `Config.xcconfig` defines neither legal key — it had read
the file inside the window where a break-test had deliberately removed them. The file defines both.

*Round 6 first returned "0 findings" and that was not convergence.* All six agents had died on a
spend limit — `agents_error: 6, agents_done: 0` — and the empty result was an artifact of the
failure, not a result. It was re-run. **An empty result from a fleet that never ran looks identical
to an empty result from a fleet that found nothing**, and only the error count distinguishes them.

## Least confident, worst first

1. **The `.late` restore test asserts exactly five reads**, which couples it to
   `EntitlementConfirmation.restoreSchedule` having four entries. Changing that schedule breaks this
   test in a way whose message will not obviously say why. It is pinned deliberately — the read count
   is what proves the slow path ran rather than the fast one — but it is the most brittle assertion
   added here.
2. **The renewal disclosure is gated on `canOffer`**, so it does not render on any device today, no
   App Store Connect product existing. It will render during review, when a product does. That
   reasoning is sound and untested against a real storefront.
3. **The report documents' line numbers.** Three correction passes each found stale anchors from the
   pass before, because the tree kept moving. File and symbol names were verified; integers may be off
   by a few. Both documents say so at the top.

---

## Still open, and the owner's

- **`blocked.md` §19 is narrowed, not closed.** `Config.xcconfig` is gitignored; whatever machine
  cuts the TestFlight archive needs the same two lines. The new test makes that fail loudly.
- **The export audit's central question is a copy judgment, deferred.** One route, one child — a
  two-child household takes two downloads. *"The whole archive"* means complete-not-partial
  everywhere else in this repository, and under that reading the paywall line is true.
- **The App Privacy labels need a human decision on the child who is not a user**, and probably an
  attorney's read. The report flags it rather than mapping it to something convenient.
- **The marketing site's `/terms` still says "both parents."**
