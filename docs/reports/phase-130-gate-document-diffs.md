# Phase 130 — proposed gate-document diffs, unapplied

`docs/decisions.md`, `docs/blocked.md`, `docs/phase-queue.md` and `docs/roadmap-status.md` were
**not edited** by phases 128 or 130. This file holds what those edits would be, for owner approval.

Nothing here is applied. Apply by hand, or say the word and I'll land it as a docs-lane phase.

---

## 1. `decisions.md` — a new row, superseding the Vellum row, which stays intact

Insert **above** the current `**The app is called `Vellum`**` row at `:120`. That row is **kept
whole and unedited** — the precedent it set itself is explicit: *"a decision that erases the one it
overturned cannot be revisited."*

```diff
+| **The app is called `Pocket Chronicle`** — settled Aug 27, 2026 by the owner, superseding the `Vellum` row below | **The trigger was an attorney's trademark-conflict finding, not a preference**, which makes this the first rename of the three that was forced rather than chosen. Open item 15 has asked since Aug 17, 2026 for exactly this artifact — a clearance answer on `Vellum` — and it has now been answered in the worst of the two available ways. **The `Vellum` row below is kept rather than edited**, for the reason that row set when it kept `Dogear`. **Three names, deliberately different, and the difference is not an inconsistency to fix:** `CFBundleDisplayName` is **`Chronicle`** (home screen, the Settings app's list, share sheet, notification titles), `CFBundleName` is **`Pocket Chronicle`** (the `ASWebAuthenticationSession` consent alert), and the App Store name is **`Pocket Chronicle`**. The store name is sixteen characters and the home-screen label truncates around eleven; a display name that is a substring of the store name is ordinary — Chrome, Maps and Photos all do it. **The precedent holds for a third time: display strings move, identifiers do not.** `manifest.format` stays `rascal-export` — **three renames now**, and the break-test pinning that literal already existed at `api/tests/test_export.py:359`; `API_HOST` stays `rascal-api.fly.dev`; the bundle id stays `com.travisterry.childarchive`; the URL scheme stays `childarchive`; the two subscription product identifiers stay. The download filename is decoration and moved again, `vellum-<child>-<date>.zip` → `pocket-chronicle-…`, with `api-contract.md:651` moved in the same commit. **Phase 128 did the `api/` half** (PR #176, merged): email subjects and bodies, `wellknown.py`'s public HTML, `mail_from`, the export viewer, the admin console, and the social brand prompts. **Phase 130 did the `ios/` half**: both name keys in all four plists, the wordmark, and every user-facing string, each taking the name the surface it names actually renders. **`docs/marketing/email-sequence.md` and `api/seeds/email_copy.yaml` were deliberately not touched** — the markdown's header forbids an agent editing it and the YAML is generated from it. **Four lessons this rename adds to the two the row below records.** **(1) The dangerous prose is the prescriptive kind, not the historical kind.** The last rename's lesson was that substituting history makes it false. This one found the opposite failure: four plist comments and a test asserted an *invariant* — that both name keys hold the same string and "all four read X and must stay that way" — that was true when written and that this rename **breaks by design**. Prose that tells the future what to do goes stale in a way prose about the past cannot. **(2) A test that pins two things to one value hides the split.** `GoogleSignInTests` looped `["CFBundleName", "CFBundleDisplayName"]` against one expected string across all four plists. A substitution rename would have left it **green** while putting one name in both keys — the identical failure phase 82 shipped and phase 114 caught. It now pins each key separately and asserts they differ. **(3) Grep cannot see a wordmark.** The name was drawn as geometry in *two* places — `ios/.../Wordmark.swift` and, unrecorded anywhere, the admin console's `index.html` and `cards.js`, which put it on every generated social asset. Neither carries the string. A text rename would have flipped `aria-label="Vellum"` to the new name while the letterforms still spelled the old one. **(4) The live copy was not in the file the brief protected.** The two off-limits email files hold nine occurrences between them — five in the markdown, one of which is its H1, and four in the YAML, all four of those in `welcome[].body` — and the welcome sequence is not built. What actually mails daily carried the name in `broadcast.py:177` and `config.py:175` — ordinary code, no header, no warning. **What is still owed:** a drawn lockup (both wordmarks currently set type at the display weight, flagged in both files), the subscription group's display name in App Store Connect, and the marketing site, which is a different repository. |
 | **The app is called `Vellum`** — settled Aug 17, 2026 by the owner, superseding the `Dogear` row below | **Vellum is the name.** …
```

---

## 2. `decisions.md` — open item 15, closed with its outcome, plus a successor

**Item 15 must not be closed as resolved.** Its own text says what would close it: *"a clearance
search, or an owner decision to accept the risk explicitly."* A rename supplies neither — it
**retires the question** and raises an identical, unanswered one about the new name.

Two edits at `:268`:

```diff
-| **15** | **The Vellum trademark has never been cleared** | **P1 — before the App Store listing, and before the first marketing send** | …
+| **15** | ~~**The Vellum trademark has never been cleared**~~ — **closed Aug 27, 2026, by the name being retired rather than by the question being answered** | ~~**P1**~~ ~~**P3**~~ — **closed** | **Outcome: an attorney found a conflict, and `Vellum` is gone.** …[existing body kept verbatim]… **What this item cost, recorded because the item existed to make the cost visible:** four Vellum-branded marketing broadcasts sent from production on Aug 19–22, 2026 and unrecallable; a domain, `getvellumapp.com`, registered and DNS-configured; an identity kit of twelve drawn assets under `docs/app-icon/` (ten SVGs, one PNG, one HTML), now superseded wholesale; a wordmark ported into the iOS app and the admin console as geometry, both now reduced to type until a new mark is drawn; and about a week. **The item worked.** It was filed on Aug 17 specifically so *"proceeded knowingly"* would not decay into *"nobody checked"*, and the thing it was holding open is exactly the thing that came true. **What it did not do is prevent the cost**, because a filed risk is not a mitigation — the four sends happened while this row asserted they had not, and the row was corrected three days late. ⚠️ **The row also carried an internal contradiction from Aug 18 until now** — a priority column reading `P1` above a body reading *"Priority drops from P1 to P3"* — which is fixed here rather than carried forward. ⚠️ **One claim in this row was wrong and is corrected on closing:** it asserts *"the icon the owner chose has the wordmark drawn into the front card, so the artwork encodes the name"*, and uses that to argue the cost has "the longest tail". **The shipped icon carries no lettering at all.** `docs/app-icon/render-appicon.mjs:29` reads `rascal-icon-fan.svg` — five fanned cards, no type — and that is what `AppIcon-1024.png` is. The wordmark-bearing variant is `vellum-icon-fan.svg`, which nothing wires up. The app icon needed **no change** for this rename. |
```

```diff
+| **26** | **The `Pocket Chronicle` trademark has never been cleared either** | **P1 — before the App Store listing, and before the next marketing send** | **Filed Aug 27, 2026, at the moment item 15 closed, and filed *by* the phase that closed it.** Item 15 existed so that an uncleared name could not quietly become an assumed-cleared one; closing it without opening this would reproduce that exact gap for the replacement. **No clearance search has been run on `Pocket Chronicle`.** The domain `pocketchronicle.app` is registered and serving `/terms/` and `/privacy/`, which is evidence of availability as a domain and **no evidence at all about a mark**. **What makes this cheaper than item 15 was, and the window is open now:** nothing has been created in App Store Connect, so the subscription group's display name is still free to change; no broadcast has gone out under the new name; the App Store listing does not exist. **What makes it more expensive if it is wrong:** this would be the fourth name, and the third rename in eleven days. **What would close this:** a clearance search with its classes, date and result recorded here — the artifact item 15 asked for twice and never received. An owner assurance that a check happened is recorded but does not close it, for the reason item 15 already established. |
```

---

## 3. `blocked.md` §19 — the paywall legal links, now answered

§19 is *"The paywall has no Terms and no Privacy link, and it is two lines in a gitignored file"*
(`:1395`). Both lines now have real values. Strike and date, do not substitute:

```diff
+> **Aug 27, 2026 — answered, and the two lines are filled in.** The owner supplied
+> `https://pocketchronicle.app/terms/` and `https://pocketchronicle.app/privacy/`; both were
+> confirmed **200** by `curl` before being written. Phase 130 set them in
+> `ios/Rascal/Config.xcconfig.example` **and** in the gitignored `ios/Rascal/Config.xcconfig`, so
+> this machine's build is correct — **but only the `.example` is in a diff**, so any other checkout
+> still needs the two lines by hand. That is the half of this section that stays open.
+>
+> ~~The prescription below names `https://getvellumapp.com/terms`.~~ — **struck Aug 27, 2026:**
+> that domain belongs to a retired name. The paragraph is kept because the `//` trap it documents
+> is still live and still the reason these values are written `https:$()/$()/…`.
+>
+> **The gap this section should now name instead:** `SubmissionComplianceTests` asserts these URLs
+> resolve to a `URL` with a non-empty host and **never asserts _which_ host**. It would have
+> passed green against an unregistered domain. The check that mattered was `curl`, run by hand.
```

---

## 4. `blocked.md` §13 and §10 — amend by strike-and-date

**§13** (`:957`, *the marketing site and the email provider*) — its Aug 18 domain paragraph is a
true record of an errand that happened and **is not edited**. Append:

```diff
+> **Aug 27, 2026 — the domain in this section names a retired product.** `getvellumapp.com` was
+> registered, put on GitHub Pages with HTTPS enforced, and had `mail.getvellumapp.com` verified at
+> Resend. **All of that happened and the record of it stays exactly as written.** The product is
+> now Pocket Chronicle and `pocketchronicle.app` is serving. **What this section does not yet say,
+> and what somebody has to decide:** whether the old domain redirects, whether the Resend sending
+> subdomain moves, and what happens to the four broadcasts already sent from it. None of that is
+> in this repository's reach. See §23, which asks a narrower version of the same question.
```

**§10** (`:540`, *monetization, a prerequisite errand*) — the App Store Connect walkthrough:

```diff
+> **Aug 27, 2026 — one value in the walkthrough below changed and it is still free to change.**
+> The subscription group's display name is `Pocket Chronicle Membership`, not `Vellum Membership`.
+> `SubscriptionProducts.groupName` was updated in the client, but **that constant is read by
+> nothing** — it records what the app was built against. **The name only becomes real when it is
+> typed into App Store Connect**, which has not happened, which is the only reason this was free.
+> **The two product identifiers are unchanged and must stay so:** they are permanent on first save.
```

---

## 5. `phase-queue.md` — the twenty-first strike

`:81` currently ends *"The highest number used is 129. A genuinely new phase takes 130."*

```diff
-**The highest number used is 129. A genuinely new phase takes 130.**
+~~**The highest number used is 129. A genuinely new phase takes 130.**~~ — **struck a twenty-first
+time on Aug 27, 2026, by 130 taking the number this sentence offered.** **130 is the iOS half of
+the Pocket Chronicle rename** (iOS lane, branch `ios/phase-130-pocket-chronicle`), paired with
+**128**, the API half (PR #176, merged). **The split was the owner's call** after the brief asked
+for a single cross-lane PR, and it is the shape the previous rename already used:
+`CLAUDE.md:16` forbids one branch touching both lanes, and the Dogear → Vellum rename was itself
+two phases — 71 and 73, PRs #119 and #121, merged one minute apart. **128's row was written by
+phase 129 rather than by 128 itself**, which is the gap `:242` exists to close: 128 existed as a
+branch with no row anywhere under `docs/` for long enough that 129's allocation had to discover it
+with `git for-each-ref`. It worked, and it worked because that command was run. **The highest
+number used is 131. A genuinely new phase takes 132.** **131 is the marketing domain**
+(API lane, branch `api/phase-131-pocket-chronicle-domain`): `pocketchronicle.app`, split out of
+130 only because `CLAUDE.md:16` forbids one branch touching both lanes.
```

---

## 6. `roadmap-status.md` — two ledger rows

```diff
+| **128** | Vellum becomes Pocket Chronicle, the API half | ✅ **shipped Aug 27, 2026** — PR #176, merged | API lane, branch `api/phase-128-pocket-chronicle`. Email subjects and bodies, `wellknown.py`'s public page, `mail_from`, the export viewer, the admin console, the social brand prompts, and the export filename with `api-contract.md:651` beside it. **Three things the brief's file list did not name**: the live broadcast footer and From line (the two protected email files are dormant — the nine occurrences between them are five in the markdown, one of which is its H1, and four in the YAML — all four of those in `welcome[].body` — and the welcome sequence is not built); the admin wordmark, drawn as an SVG path and a canvas `Path2D` that carry no `vellum` token at all; and `api-contract.md`. `manifest.format` unchanged and already break-tested. Suite `1430 passed / 7 failed / 1 skipped` — **the same 7 fail on unmodified `main`** (local `.env` gives real vendor keys to tests asserting their absence). |
+| **130** | Vellum becomes Pocket Chronicle, on the phone | 🟡 **built and green Aug 27, 2026** — PR pending | iOS lane, branch `ios/phase-130-pocket-chronicle`, paired with 128. **Both name keys in all four plists, split on purpose**: `CFBundleDisplayName` = `Chronicle`, `CFBundleName` = `Pocket Chronicle`. **The invariant that broke is the finding**: until today both keys held one string, three comments said so, and a test looped both keys against **one** expected value across all four files — so a substitution rename would have stayed green while putting one name in both keys, the same failure phase 82 shipped and 114 caught. The test now pins per key and asserts they differ. Every user-facing string takes the name **its surface renders** — *"Settings → Chronicle → Notifications"*, *"Open Chronicle and sign in"*, but *"Pocket Chronicle writes to this phone first"*. `Wordmark.swift` dropped 208 lines of Bézier geometry spelling the dead name and **sets type at the display weight as a stopgap**; a real lockup is owed and `docs/app-icon/` is marked superseded rather than renamed, because a file named `pocket-chronicle-wordmark.svg` that draws *Vellum* is worse than one named honestly. **The app icon needed no change** — it carries no lettering, which is the third rename that has paid off. `Vellum.storekit` → `PocketChronicle.storekit`, safe **for the build** — no `.pbxproj`, scheme or test-plan reference; five live documents still name the old path and are corrected separately. Legal URLs repointed at `pocketchronicle.app`, **confirmed 200 by `curl` first** — `SubmissionComplianceTests` asserts they resolve to a URL with a non-empty host and never asserts **which** host, so it would have passed against an unregistered domain. **1242 tests in 150 suites passed, cold, `DerivedData` deleted, zero warnings under the four-directory gate.** |
```

---

# Addendum — Aug 27, 2026, after a ten-dimension review of the rename

The review found operator-facing instructions in the gate documents that are now **actively
wrong** — a human typing from them would reproduce the retired name in a place that is permanent
or unrecallable. These are more urgent than the ledger rows above.

## 7. `blocked.md` §10 step 3 — the runbook still creates the group under the dead name 🔴

`:608` reads *"Create the subscription group `Vellum Membership`"* and, two lines down, *"Nothing
has been created yet, which is the only reason this edit was still possible."*

```diff
-3. **Create the subscription group** `Vellum Membership`. **Renamed from `Dogear Membership` on
+3. **Create the subscription group** `Pocket Chronicle Membership`. ~~`Vellum Membership`~~
+   — **struck Aug 27, 2026 with the third rename.** **Renamed from `Dogear Membership` on
```

**And the premise underneath it needs re-checking before anything is typed.** §25 of this same
file, written Aug 27–28, 2026, reports a TestFlight purchase against a real household and says the
products *"did"* exist in App Store Connect. If that is right, *"nothing has been created yet"* is
false, the group name may already be permanent, and `SubscriptionProducts.groupName` records a name
the store does not have. **Only the owner can look.** The client constant carries this warning in
its doc comment rather than asserting the rename succeeded.

## 8. `blocked.md` §19 — the copy-paste block ships a dead domain 🔴

`:1451` still prescribes `TERMS_URL = https://getvellumapp.com/terms`. This block is **the only
checked-in instruction for a gitignored file**, and it is where the shipped test's own failure
message sends a developer. Following it links the paywall to a retired domain, and
`SubmissionComplianceTests` cannot catch it — it asserts the URL parses with a non-empty host,
never which host.

```diff
-TERMS_URL   = https:$()/$()/getvellumapp.com/terms
-PRIVACY_URL = https:$()/$()/getvellumapp.com/privacy
+TERMS_URL   = https:$()/$()/pocketchronicle.app/terms/
+PRIVACY_URL = https:$()/$()/pocketchronicle.app/privacy/
```

Both pages confirmed **200** on Aug 27, 2026.

## 9. `blocked.md` §13 step 5 — the `fly secrets set` line signs mail with the dead name 🔴

`:1080` prescribes `fly secrets set --app rascal-api MAIL_FROM='Vellum <hello@mail.yourdomain>'`.

**`MAIL_FROM` is a Deployed secret today** (`flyctl secrets list -a rascal-api`), and a
`pydantic-settings` field takes the environment over its default — so **phase 128's edit to
`config.py:175` did not change what production sends.** Every broadcast still signs with the
retired name until this command is run with the new one. Outbound email is the surface
`decisions.md` item 15 names as unrecallable.

```diff
-| 5 | … | `fly secrets set --app rascal-api MAIL_FROM='Vellum <hello@mail.yourdomain>'` and `MAIL_PROVIDER=resend` |
+| 5 | … | `fly secrets set --app rascal-api MAIL_FROM='Pocket Chronicle <hello@mail.yourdomain>'` and `MAIL_PROVIDER=resend` |
```

**Same class, and exactly ONE more secret — not two.** `MARKETING_ORIGINS` **is** a Deployed
secret and must gain `https://pocketchronicle.app`, or the new site's subscribe form is
CORS-refused. **`MARKETING_SITE_URL` is NOT a secret** — `flyctl secrets list -a rascal-api` holds
`MAIL_FROM`, `MARKETING_ORIGINS` and `MARKETING_EMAIL_ENABLED` and no site URL — so phase 131's
default ships on the next deploy with no operator action. An earlier draft of this addendum called
them "two more secrets"; that was inferred from the shape of the names rather than read off the
list, which is the same mistake this section exists to warn about.

## 10. `blocked.md` §11 step 2 — a device checklist naming a label iOS will not render

`:889` tells the tester *"Settings → Apple ID → Sign-In & Security → Sign in with Apple → find
Vellum"*. That list renders `CFBundleDisplayName`, so the label is now **`Chronicle`** — not
`Pocket Chronicle`, and not `Vellum`.

## 11. `decisions.md` D5a — the settled record of the group name

`:43` still reads *"Subscription group **`Vellum Membership`**"*. Amend by strike-and-date the way
D5a already handled `Dogear Membership`, and carry the §25 caveat above with it.

## 12. Seven live documents still name `ios/Rascal/RascalTests/Vellum.storekit`

The path no longer exists. **Four are gate documents** — `decisions.md`, `blocked.md`,
`phase-queue.md`, `roadmap-status.md` — and are listed here. **`docs/decisions-log.md` is the
fifth**, is not a gate document, and was corrected in place. `docs/phase-briefs/phase-125-…` and
`docs/reports/phase-124-preflight.md` are dated records and are correctly left alone, as is the
mention in `docs/archive/`.
One of the gate-document mentions is an **open iOS-lane action item that names the file as the
thing to edit**, so it must move or the errand points at nothing.

---

# Addendum II — Aug 28, 2026, after a second review round

Round 2 audited round 1's fixes and found that several of them, and parts of this report, were
wrong. Those are corrected above in place. Three items are new.

## 13. `blocked.md` §10 — the *other* place the group name is printed 🔴

Item 7 above fixes step 3 of the runbook at `:608`. It misses `:590`, and `:590` is the more
dangerous of the two — a bare fenced values block under a heading that calls these values
**permanent once created**, which is exactly what a human transcribes into App Store Connect:

```diff
 ### The product identifiers, chosen Aug 16 and permanent once created
 
 ```
-Subscription group:  Vellum Membership
+Subscription group:  Pocket Chronicle Membership
 Annual:              com.travisterry.childarchive.subscription.annual
 Monthly:             com.travisterry.childarchive.subscription.monthly
 ```
```

The two identifiers are unchanged and must stay so. **Carry the §25 caveat here too**: if the
products already exist, this value may no longer be settable and the block should say which name
the store actually holds rather than which one we wish it held.

## 14. `blocked.md` §23 — an open errand whose entire action is on the retired domain 🔴

§23 is submission-blocking and its action is *"send to `hello@getvellumapp.com` from an address on
a different provider and see whether it lands or bounces"*. It also names that address as the
**App Store support contact**. Both are now the wrong domain: the product is served from
`pocketchronicle.app`, whose DNS this repository has never examined.

The section cannot simply be re-pointed — the DNS work it documents was done against
`getvellumapp.com` and is a true record of that. Amend by strike-and-date:

```diff
+> **Aug 28, 2026 — the domain in this section is retired and the errand has to move with it.**
+> Everything below about `getvellumapp.com` — the iCloud exchangers, the SPF record, the
+> `apple-domain=` TXT, the DMARC policy — was read off public DNS on Aug 25, 2026 and is a true
+> record of that domain on that day. **It is no longer the product's domain.** The App Store
+> support contact must be an address on `pocketchronicle.app`, and **none of the DNS checks in
+> this section have been run against it.** The errand is unchanged in shape and entirely
+> re-pointed: does the mailbox exist, and does a message to it arrive?
```

## 15. `roadmap-status.md` — a third ledger row

§6 proposes rows for 128 and 130 only. 131 shipped inside the diff this report covers:

```diff
+| **131** | The marketing domain moves to `pocketchronicle.app` | 🟡 **built and green Aug 27, 2026** — PR #178 | API lane, branch `api/phase-131-pocket-chronicle-domain`. Split out of the rename phases because a domain is not display copy and the brief said to ask rather than invent one; the owner supplied it mid-run with `/terms/` and `/privacy/` already serving, both confirmed **200** by `curl` before either value was written. `marketing_site_url` is the broadcast footer's href and the post-confirmation redirect target, so this is not decoration. **`MARKETING_SITE_URL` is not a Fly secret**, so the default ships on the next deploy — unlike `MAIL_FROM` and `MARKETING_ORIGINS`, which are, and which need `fly secrets set` by hand. |
```

---

# Addendum III — Aug 28, 2026, round 4

Round 4 found two things. The second is a wording fix, applied above. The first is the most
consequential miss of the whole review, and four rounds walked past it.

## 16. `phase-queue.md` §build queue — the one bullet that would put the retired name on the App Store 🔴

`docs/phase-queue.md:530` is a **live, prioritised build-queue item** — the file's own header says
*"This file says what to do next, one line each. Delete a line when it is done."* It is the single
place in the repository that carries the **remaining owner errand** for the rename. It reads:

```
- **Rename to ~~`Dogear`~~ `Vellum` — code is done, ~~three things left~~ two, and both are yours.**
  …
  All four bundles read `Vellum` in source today, and `project.pbxproj` sets no
  `INFOPLIST_KEY_CFBundleDisplayName` override, so **a device still showing the old name is a
  stale install rather than a source defect**
  …
  **Left: the App Store Connect / TestFlight listing name**, and **the repo name plus `docs/` prose**
```

**Followed as written, this creates the public App Store listing under `Vellum`** — the mark an
attorney found a conflict on, and the entire reason for phases 128, 130 and 131. The proposed new
open item 26 above says the window is open *precisely because* "the App Store listing does not
exist"; this bullet is the one instruction standing between that window and closing it wrong.

Its bundle sentence is also now false: all four plists read `CFBundleDisplayName = Chronicle` and
`CFBundleName = Pocket Chronicle`.

```diff
-- **Rename to ~~`Dogear`~~ `Vellum` — code is done, ~~three things left~~ two, and both are yours.**
+- **Rename to ~~`Dogear`~~ ~~`Vellum`~~ `Pocket Chronicle` — code is done, ~~three things left~~ two, and both are yours.**
+  **A third name, struck Aug 27, 2026** on an attorney's trademark-conflict finding — the same
+  shape as the Aug 18 correction below, arriving for the same reason: a queue item that names a
+  product outlives the name.
```

```diff
-  only as current as the thing it was run against, and this one outlived two renames.** All four
-  bundles read `Vellum` in source today, and `project.pbxproj` sets no
-  `INFOPLIST_KEY_CFBundleDisplayName` override, so **a device still showing the old name is a stale
+  only as current as the thing it was run against, and this one outlived two renames — three now.**
+  ~~All four bundles read `Vellum` in source today~~ — **struck Aug 27, 2026.** All four read
+  `CFBundleDisplayName = Chronicle` and `CFBundleName = Pocket Chronicle`; the two keys hold
+  different strings on purpose. `project.pbxproj` sets no
+  `INFOPLIST_KEY_CFBundleDisplayName` override, so **a device still showing the old name is a stale
   install rather than a source defect** — a distinction that cost another session a retracted
```

```diff
-  so it was decidable before the name and would not have changed after it. **Left: the App Store
-  Connect / TestFlight listing name**, and **the repo name plus `docs/` prose** — the last is
+  so it was decidable before the name and would not have changed after it. **Left: the App Store
+  Connect / TestFlight listing name — which must be `Pocket Chronicle`, not `Vellum`** (see open
+  item 26: the new name has had no clearance search either, and the listing is the surface that
+  makes that expensive) — and **the repo name plus `docs/` prose** — the last is
   cosmetic and deliberately not swept, because it would bury a real diff under a few hundred
```

**All three hunks were checked against the current text of `phase-queue.md` line by line.** An
earlier draft of this addendum wrote them from the quoted excerpt above rather than from the file,
and two of the three would not have applied — the line wrapping differs. Which is the same failure
this addendum is about, one level down.

**Why four rounds missed it.** Every completeness sweep grepped for `vellum` and read the hits.
This bullet was *in* those results every time, and was classified as a gate document — correctly —
and therefore as already-covered by this report. It was not covered: §5 amends only `:81`, the
phase-number header, and §12 only the `Vellum.storekit` bullet at `:503`. **"It is a gate document"
answers who may edit it, not whether anybody has.** The lesson for the next sweep: a gate-document
hit is only accounted for once it is matched to a specific proposed hunk in this file, by line.
