# Phase 125 — Settings membership copy revision

> **Allocation.** Number assigned Aug 25, 2026 by the owner — *"call it whatever you want"* — and
> **measured, not inferred**: `max + 1` across the four prescribed sources, which answered 123,
> 121, 123 and 122. Lane: **iOS**.
>
> **Branch: `ios/phase-124-app-review-compliance`, not `ios/phase-125-membership-copy`.** The
> brief below names its own branch; the owner's instruction of Aug 25, 2026 was *"I have more for
> this PR"*, so this phase rides 124's branch and pull request rather than taking its own. The
> precedent is phases 102, 104 and 105, which shared one branch by the same call. **Nothing else
> in the brief is suspended by that** — the scope, the match rule and the out-of-scope list below
> are unchanged.
>
> The brief below is the owner's text, unedited apart from the number in this heading.

**Lane:** iOS (`travist6983/Project-Rascal`, `ios/`)
**Branch:** `ios/phase-125-membership-copy`
**Phase number:** left blank deliberately. The owner assigns it. Do not infer one from
`roadmap-status.md`, do not pick the next integer, do not proceed with a placeholder.

---

## 0. What this phase is

Eight user-visible strings in the Settings → Membership surface are replaced with strings
supplied verbatim below. **No new copy is authored by you.** `docs/design/free-tier-copy.md`
forbids an agent writing user-visible strings for this surface, and that rule is not suspended
here — it is satisfied by the owner having authored every replacement in §3.

This is a copy phase. No behaviour changes, no state machine changes, no wire changes, no new
fields decoded, no gating touched.

---

## 1. Preflight gates — hard stop on any failure

Each gate below stops the run and produces a report. Do not "note it and continue."

1. **Phase number.** If the owner has not written a number into the heading of this file, stop.
2. **`docs/design/free-tier-copy.md` exists and is readable.** It has been reported missing in
   this repository before and recovered from another lane. If it is not on disk, stop and say
   so — do not reconstruct it, and do not proceed against the Swift alone.
3. **Read, in full, before editing anything:** `docs/design/free-tier-copy.md`,
   `docs/decisions.md` (D2 and D3 as amended Aug 21 2026), `docs/design-system.md`,
   `docs/roadmap-status.md` rows for phases 108, 110, 112 and 113.
4. **Working tree clean, branch cut from `origin/main` at its current head.** Record the SHA.
5. **Cold build green at zero warnings before you start.** 21 inherited warnings is a stale
   claim in three places; phase 48 cleared exactly those. Zero is the baseline. If the tree is
   not at zero, stop and report the warnings rather than adding to them.

---

## 2. Inventory before you edit

Produce this inventory and put it in the PR body. Do not edit a single string until it exists.

- Every render site of each string in §3, found by grep, with file and line.
- Every **state variant** of the two action rows and the status row —
  `MembershipPresentation` and whatever drives `SubscriptionSection` express nine household
  states, and the screenshot this phase was written from shows exactly one of them.
- Whether the "what stays free" block in §3.5–3.8 renders on more than one surface. Phase 112's
  row says the block renders on the membership card **in every state, subscribed included**, and
  it may also render inside the membership sheet. **Changing it changes every one of those
  surfaces.** List them.

---

## 3. The replacements

**Match rule, and it is the whole safety property of this phase:** replace a string only where
the current value matches the "from" text below **exactly and in full**. Where a state variant
exists that no line below matches, **leave it alone** and list it in the PR under *Strings this
phase did not author*. Do not adapt, do not pattern-match, do not write a sibling string so the
states read consistently. An inconsistent set of states is a smaller defect than an agent-authored
string on this surface.

### 3.1 Status row label

- from: `Household`
- to: `Your household`

**The status *value* is out of scope.** `Everything open` was chosen by the owner from three
candidates in phase 112, and every other output of `MembershipPresentation.settingsStatus(for:)`
is out of scope with it. Do not touch that function.

### 3.2 Membership action row — title

- from: `See the subscription`
- to: `See what membership includes`

### 3.3 Membership action row — subtitle

- from: `One price for the whole household — both parents, every child.`
- to: `One price covers everyone in the house — every parent, every child.`

Rationale, so you do not "improve" it back: `both parents` presumes a two-parent household. The
only user today is one parent with one child.

### 3.4 Restore row — subtitle

- from: `Rarely needed — your subscription follows the household, not the phone.`
- to: `If you've paid before and this phone doesn't know it yet.`

**The restore row title `Restore a purchase` does not change.** App Review 3.1.2(c) wants that
control present and recognisable; renaming it is a rejection risk for no gain.

### 3.5 Free block header

- from: `What stays free, always`
- to: `Yours either way`

Match case-insensitively for this one line only, since the surface renders it uppercased by
style rather than by content. **Do not commit an uppercased literal** — if the current literal is
sentence case and the caps come from a text style, keep it that way.

### 3.6–3.8 Free block bullets

- from: `A question every day, forever`
  to: `A new question every day, with no limit and no countdown.`
- from: `Everything you've already written or captured`
  to: `Everything you've already written and captured stays yours.`
- from: `Search, and a full export of the whole archive`
  to: `Search the whole archive, and export all of it whenever you want.`

Note the terminal full stops. The current strings are fragments; the replacements are sentences,
and the change is deliberate.

---

## 4. Constraints these strings must survive

Verify each against the tree rather than asserting it.

1. **`free-tier-copy.md` §4 bans streaks, counts of skipped items, and percentage complete** —
   a rule about shapes, which no grep enforces. None of §3 introduces one. Confirm by reading.
2. **The banned "Your archive will be…" sentence, in words or in numbers.** No date, no
   countdown, no deletion clock appears in any string above. `eligible_at` is deliberately absent
   from the schema this surface decodes (phase 113); do not add a decode for it.
3. **No gendered pronoun.** Seven strings on this surface render through the client-side
   `PromptTokens` table against `PromptSubject.unknown` because a two-child household has no
   correct pronoun. None of §3 needs a token — check that none of the strings you are *replacing*
   carried one. **If a "from" string above turns out to contain a token, stop and report it**;
   the replacement would silently drop it.
4. **D3 as narrowed.** "Everything you've already written and captured stays yours" is a claim
   about the archive surviving a lapse. D3 says nothing already written becomes unreadable,
   unexportable or unsearchable because a subscription ended — so the claim holds. **If
   `free-tier-copy.md` says otherwise, or if anything in `decisions.md` contradicts it, stop and
   report both sides rather than shipping the string.**
5. **Contrast.** Phase 112 moved nine `.typeRole(.body)` sites from `Color.terracotta` (4.36:1)
   to `terracottaDeep` (6.47:1) and added a guard whose matcher is a word boundary. This phase
   changes no colours. **Run that guard and confirm it still passes.** If a longer string causes
   a row to re-lay-out into a different type role, that is a change and it needs reporting.
6. **`docs/design/free-tier-copy.md` is updated in the same commit as the Swift.** The file is
   the source of truth for these strings; Swift changed without it is a divergence that the next
   phase inherits as a mystery. Mark the eight replaced strings as **owner-authored, approved
   <date>** in that file.

---

## 5. Out of scope — do not touch

- `MembershipPresentation.settingsStatus(for:)` and all nine of its outputs.
- The paywall / membership sheet's own body copy, prices, and plan rows.
- `Restore a purchase` as a title.
- Any gating, any `access` handling, any decode. D9 stands: an absent or unrecognised `access`
  means **entitled**, never locked.
- `ios/Rascal/RascalTests/Vellum.storekit`. It is known-wrong (two `introductoryOffer` blocks
  against a server-granted trial) and it is not this phase's defect to fix.
- `travist6983/Rascal-Marketing`. The site carries parallel claims. **If any string in §3
  contradicts the live site, report it — do not edit the other repository.**
- `docs/decisions.md`. If you believe a decision needs amending, **return a diff in the PR body
  for the owner to apply**. Do not edit that file.

---

## 6. Break-tests

For each, break it deliberately, watch the test fail, restore it. A test that has never been seen
red is not evidence.

1. Revert one replaced string to its old value → the assertion pinning the new string fails.
2. Reintroduce `Color.terracotta` at `.typeRole(.body)` on a membership action row → the phase
   112 contrast guard fails. (This is the guard that once passed while the defect was live,
   because it matched `Color.terracotta)` and missed the ternary form. Confirm it catches the
   ternary.)
3. Drop the terminal full stop from bullet 3 → the assertion fails, i.e. the tests pin the exact
   literal and not a prefix.

---

## 7. Adversarial re-read before you open the PR

Answer each in the PR body, in writing.

- Did I author any user-visible string not present verbatim in §3? Quote anything I am unsure about.
- Did I change a string in a state variant the owner did not supply a replacement for?
- Does the free block now render differently on a surface I did not inventory in §2?
- Is `free-tier-copy.md` updated, and does it now disagree with the Swift anywhere?
- Did a longer replacement string cause truncation, a line-wrap change, or a Dynamic Type
  overflow at AX5? Say which sizes I actually checked, and on what device.
- Is the cold build still at zero warnings?

---

## 8. PR requirements

- Title: `phase 125 — settings membership copy revision`
- Body carries: the §2 inventory, the §4 verification results, the §6 break-test evidence, the §7
  answers, and *Strings this phase did not author*.
- **Least confident, ranked.** Three things in this PR most likely to be wrong, worst first, with
  what would prove each one.
- **Verification honesty clause.** State plainly which claims in this PR were verified by running
  or reading, and which are assertions. If a check was skipped, say it was skipped — do not
  describe an intention as a result.
- Write the `roadmap-status.md` row **at allocation, before the first line of code**, as the last
  seven phases have. Mark it 🔵 open. Correct it at merge.
