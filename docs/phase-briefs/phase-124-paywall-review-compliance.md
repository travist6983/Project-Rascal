# Phase 124 — Paywall review compliance: 3.1.2 disclosures and Restore Purchases

> **Allocation.** Number assigned Aug 25, 2026 by the owner — *"call it whatever you want"* — and
> **measured, not inferred**: the four prescribed commands answer `git log --all` **123**,
> `gh pr list` **121**, `grep docs/` **123**, `git for-each-ref` **122**, so `max + 1` is 124.
> `phase-queue.md` offered the same number in its own sentence. Lane: **iOS**. Branch:
> `ios/phase-124-app-review-compliance`, cut from `origin/main` at `26bbf5a`.
>
> **Preflight was run before this file was committed and it stopped.** The findings are in
> `docs/reports/phase-124-preflight.md` and they change what this phase is: most of §1 and
> nearly all of §2 shipped in phase 110 and are pinned by
> `ios/Rascal/RascalTests/AppReviewRequirementsTests.swift`. Read the report before the brief.
> The brief below is the owner's text, unedited apart from the number in this heading.

Lane B (iOS). Blocks App Store submission. Does not depend on Lane A.

---

## Preflight gates

Any failed check stops the run. Produce a report, change nothing.

1. Read `roadmap-status.md`. Confirm no phase is already in flight on the iOS lane. If one
   is, stop.
2. Read `decisions.md`. Confirm D1 (annual preselected) and the free-tier decision are
   still as recorded. If the paywall you find contradicts them, stop and report both sides
   rather than reconciling.
3. Confirm the phase number in this filename does not collide with anything in
   `phase-queue.md`. If the number is still `XX`, stop — Travis assigns it.
4. Locate the paywall view. Report its path before editing. If there is more than one
   paywall entry point, list all of them and stop.
5. Confirm `StoreKit Configuration` is `None` in the Run scheme. If a `.storekit` file is
   selected, stop — the work is untestable.

---

## Scope

Two changes to the paywall, plus one file of constants. Nothing else. Do not restyle, do
not refactor purchase logic, do not touch entitlement resolution.

### 1. Guideline 3.1.2 disclosures

The paywall must display, on the paywall screen itself:

- Subscription title
- Length of the subscription period
- Price, and price per unit of time
- A tappable link to Terms of Use
- A tappable link to Privacy Policy

The plan rows already carry title, duration and price and are correct. What is missing is
the two links, and a single line stating renewal terms.

Add below the plan rows and above `Become a member`:

> Membership renews automatically until cancelled. Cancel any time in your Apple Account
> settings.

Then a row of two links, `Terms of Use` and `Privacy Policy`, opening in `SFSafariViewController`
— not an external Safari jump, which takes the reviewer out of the app.

URLs, as constants in a new `Legal.swift`:

```swift
enum Legal {
    // Apple's standard EULA. Swap to https://getvellumapp.com/terms once app-specific
    // terms covering the subscription exist — the current /terms page covers the
    // marketing site and waitlist only and explicitly states the app has no terms yet.
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyPolicy = URL(string: "https://getvellumapp.com/privacy")!
}
```

Typography and colour come from `design-system.md`. The disclosure line is secondary ink
at the smallest supported size; the links are periwinkle `#5566D6`. No new tokens.

### 2. Restore Purchases

A visible control, not only the `Transaction.updates` listener. Reviewers look for it.

- Place it beside `Not now` at the bottom of the paywall.
- Calls `AppStore.sync()`, then re-reads entitlement from the server. The device does not
  decide the result (D5).
- Three states: idle, in-flight (disable the control), and finished.
- On success with an entitlement found: dismiss the paywall.
- On success with nothing found: a non-modal message — "No previous membership found on
  this Apple Account." No error styling. Not finding a purchase is a normal outcome.
- On failure: "Couldn't reach the App Store. Try again in a moment." No stack trace, no
  error code in the copy.

Also expose the same action in Settings, so a member who reinstalls and never sees the
paywall can still restore.

---

## Copy rules

Binding, from `CLAUDE.md`. No streaks, no urgency, no guilt, no countdowns, no
exclamation marks, no confetti. Do not write "Don't lose access" or any variant. The
restore affordance is a utility, not a save.

---

## Break-tests

Write these. They must fail before the change and pass after.

1. Paywall renders both legal links, and both resolve to a non-nil `URL`.
2. The renewal-disclosure string is present in the paywall's rendered text.
3. Restore control exists and is hit-testable.
4. Restore in-flight disables the control (no double-tap re-entry).
5. Restore that finds no entitlement does not dismiss the paywall and does not surface
   error styling.
6. Restore reads entitlement from the server after `AppStore.sync()` — assert the
   entitlement call happens, and that no code path sets entitlement locally.

If an assertion and the implementation disagree, assume the assertion is right. Stop and
report both sides. Do not edit a test to make it pass.

---

## Adversarial re-read

Before opening the PR, re-read the diff and answer in the PR body:

- Does any new code write entitlement state on the device? Quote the lines that prove not.
- Does the restore path duplicate logic that already exists in the `Transaction.updates`
  listener? If so, say where, and whether they can diverge.
- Is any string in the diff a guilt lever or an urgency state under a different name?
- Does the paywall still fit on the smallest supported device without the plan rows being
  pushed off-screen? Two links and a disclosure line is roughly 60pt of new height.
- Did anything outside the paywall, `Legal.swift`, Settings, and the new tests change?

---

## PR requirements

- One PR, scoped to this phase.
- Screenshots: paywall on the smallest and largest supported device, both showing the
  disclosure line and both links.
- Rank the three things you are least confident about, most doubtful first.
- State plainly what you verified by running versus what you verified by reading. If a
  test was not executed, say so.

---

## Out of scope — do not touch

- The review screenshot and review notes in App Store Connect (manual).
- Account deletion / Guideline 5.1.1(v). Separate phase, separate blocker.
- `CFBundleDisplayName`, app naming, subscription display names.
- Writing app-specific terms of service. Noted above as a follow-up.
- Free-trial mechanics. The trial is server-granted; nothing on the paywall changes it.
