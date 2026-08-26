# Phase 124 — preflight report

**Aug 25, 2026.** Run against `origin/main` at `26bbf5a`, before any edit. Nothing in the tree was
changed by this pass. The brief is `docs/phase-briefs/phase-124-paywall-review-compliance.md`.

**The run stopped at gate 3 and gate 4.** Gate 3 has since been cleared — the owner assigned the
number. Gate 4 stands as written and is discussed below.

---

## 1. Gate results

| # | Gate | Result |
|---|---|---|
| 1 | No phase in flight on the iOS lane | ✅ **Pass.** In flight at the time of the run: **106** (API lane, built and uncommitted on no branch), **109** (marketing lane, allocated). Neither is iOS. |
| 2 | D1 and the free-tier decision unchanged | ✅ **Pass.** See §2. |
| 3 | Phase number assigned | ❌ **Failed at run time** — the brief's heading read `XX`. Cleared Aug 25, 2026 by the owner. |
| 4 | One paywall entry point | ❌ **Failed.** Three. See §3. |
| 5 | `StoreKit Configuration` is `None` in the Run scheme | ✅ **Pass.** See §4. |

---

## 2. Gate 2 — the decisions, checked rather than assumed

**D1 is as recorded.** `docs/decisions.md` — subscription with a permanent free tier, **$59.99/year
or $5.99/month, annual exactly two months free, annual preselected**. The one amendment (Aug 22,
2026, phase 111) is about *where the fourteen trial days live* — server-side, with no Apple
introductory offer — and touches nothing this phase changes.

**The paywall does not contradict it.** `SubscriptionModel.plan` defaults to `.annual`
(`ios/Rascal/Rascal/Subscription/SubscriptionModel.swift:67`), which is D1's preselection, and every
price on the sheet is formatted from a `Product` rather than written out —
`SubscriptionTests.noCurrencyLiterals` scans the whole directory for the literal form.

**The free-tier decision is D2 as reversed** (Aug 21, 2026, phase 107): the free tier is the daily
question, missions are membership, and D3 as narrowed says the archive is never locked — the day is.
The sheet's *what stays free* block reads *"A question every day, forever / Everything you've
already written or captured / Search, and a full export of the whole archive"*, which is the
post-reversal shape. No contradiction to report.

---

## 3. Gate 4 — three entry points, one paywall

The gate says to stop if there is more than one paywall entry point. There are three, and they all
present the same view, so the failure is literal rather than substantive. Recorded here so the next
reader does not have to re-derive it.

The paywall view is **`ios/Rascal/Rascal/Subscription/PaywallSheet.swift`**. It is presented from:

| Surface | Site |
|---|---|
| Today board, from a locked card | `ios/Rascal/Rascal/Today/TodayScreen.swift:320` |
| Settings → Membership | `ios/Rascal/Rascal/Subscription/SubscriptionSection.swift:102` |
| The guardian-invite surface | `ios/Rascal/Rascal/Settings/GuardiansSection.swift:62` |

Every other `PaywallSheet(` in the tree is a `#Preview`. There is **one** paywall, and phase 108
deliberately retired the per-context header that used to make it read as several — the file's own
note: *"Presented from a locked card, from Settings, and from the guardian-invite surface. Same
sheet every time."*

---

## 4. Gate 5 — the scheme

`ios/Rascal/Rascal.xcodeproj/xcshareddata/xcschemes/Rascal.xcscheme` contains **no**
`StoreKitConfigurationFileReference`, and no user scheme overrides it — `xcuserdata` holds no
schemes in either the primary checkout or this worktree.

The one `.storekit` file in the repository is `ios/Rascal/RascalTests/Vellum.storekit`, and it is
referenced nowhere in the project file. The work is testable against the real sandbox. (That file
is still known-wrong for a separate reason — two `introductoryOffer` blocks against a server-granted
trial — recorded in `blocked.md` §10 and out of scope here.)

---

## 5. The finding that changes the phase: most of this shipped in phase 110

This is the part worth reading before the brief. **Phase 110 built the App Review surface**, and
`ios/Rascal/RascalTests/AppReviewRequirementsTests.swift` pins it — a file that exists because each
control's absence was *proven* rather than suspected, by deleting it from a green tree and watching
1108 tests fail to notice.

### 5.1 Guideline 3.1.2 — what is actually present

| Requirement | State |
|---|---|
| Subscription title | ✅ `Text(plan.displayName)` in `PlanRow`, `PaywallSheet.swift`. Pinned. |
| Length of the subscription period | ✅ `PlanCopy.priceLine`. Pinned behaviourally. |
| Price, and price per unit of time | ✅ Same line, formatted off the `Product`. |
| Terms of Use link | ⚠️ **In the code, absent at runtime.** `PaywallSheet.swift:446`. |
| Privacy Policy link | ⚠️ **In the code, absent at runtime.** `PaywallSheet.swift:451`. |
| Renewal-terms sentence | ❌ **Genuinely missing.** No such string exists anywhere in `ios/`. |

### 5.2 The links are a configuration gap, not a UI gap

`LegalLinks` (`PaywallSheet.swift:608-624`) reads `TERMS_URL` and `PRIVACY_URL` out of the
Info.plist, which take their values from `Config.xcconfig`. **The real `Config.xcconfig` defines
neither key.** It is untracked and lives only in the primary checkout at
`ios/Rascal/Config.xcconfig`; `Config.xcconfig.example:93-94` carries both values correctly.

So both links resolve to `nil` and render as *absent* in every build today. This is already filed
in two places: `docs/design/design-conformance-110.md` §7.4, and — as the owner-facing errand it
actually is — **`docs/blocked.md` §19**, *"The paywall has no Terms and no Privacy link, and it is
two lines in a gitignored file"*, open since Aug 22, 2026. §19 carries the exact two lines to
paste, including the `$()` split that stops xcconfig reading `//` as a comment and truncating the
value to `https:`. **Nothing in either lane's code changes**, which is why no phase has closed it.

**Consequence for the brief.** Writing a new `Legal.swift` holding hardcoded URLs would put a second
source of truth beside a working configurable one, and would route around the `url.host()` guard
that `AppReviewRequirementsTests.theHostGuardIsIntact` pins — the guard that stops a truncated
`https:` shipping as a *dead* link rather than as no link. The brief's snippet also force-unwraps
both `URL(string:)` calls, which the shipped code deliberately does not.

### 5.3 Restore is already built and already visible

The brief describes it as missing. It is not:

| Brief's requirement | Where it already is |
|---|---|
| A visible control, not only the listener | `PaywallSheet.swift:418-434`, inside `legalRow` |
| `AppStore.sync()`, then re-read from the server | `SubscriptionStore.restore()` → `SubscriptionModel.restore()` (`:459-502`) → `EntitlementConfirmation.poll` on `restoreSchedule` |
| Three states, in-flight disables the control | `isRestoring`, `.disabled(model.isRestoring)`, plus a `ProgressView` |
| Non-modal message when nothing is found | `model.notice`, rendered as a sentence under the row |
| Also in Settings | `SubscriptionSection.swift:66,74` |
| **On success with an entitlement found: dismiss** | ❌ **Not implemented.** Restore settles `purchase` to `.subscribed` and the sheet shows its terminal message plus **Done**. |

### 5.4 What is genuinely left

1. The renewal-terms disclosure line.
2. `SFSafariViewController` — the links are SwiftUI `Link`s today, which jump out to Safari.
3. Dismiss-on-successful-restore.
4. Two lines in `Config.xcconfig`, which is an owner errand rather than a code change.

---

## 6. Two places the brief contradicts a recorded decision

Reported rather than reconciled, per the brief's own instruction.

**Restore's not-found copy.** The brief supplies *"No previous membership found on this Apple
Account."* The shipped string is *"Nothing has arrived yet. If you subscribed on another device, it
can take a moment to appear."* The comment above it (`SubscriptionModel.swift:496-497`) reads:
**"Not a claim about the Apple Account. The client cannot see what Apple holds; it can only report
that nothing has arrived here yet."** The brief's line makes exactly the claim that comment forbids,
and it can be false during the confirmation gap — a household mid-poll has a membership the device
has not heard about yet.

**Restore's placement.** The brief says beside `Not now`. The shipped placement is in `legalRow`,
below the free block, with the reason written down: *"deliberately below the free block rather than
beside the action: Review requires Terms and Privacy on any paywall, and restore is a rare path that
should not compete with the two things this screen is actually for."*

Both need the owner's ruling. Neither was changed by this pass.

---

## 7. Verification honesty

**Verified by reading**, against the tree at `26bbf5a`: every file and line reference above, the
gate-2 decisions, the three entry points, the scheme's lack of a StoreKit reference, and the
contents of `Config.xcconfig` in the primary checkout.

**Not run:** no `xcodebuild`, no test execution, no cold-build warning count. Gate 5 of the *other*
brief (phase 125) asks for a zero-warning cold build as a baseline; that has not been established
here and is not claimed.
