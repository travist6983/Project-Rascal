# Free tier, locked missions, membership — the copy

> **Provenance, because this file's history matters more than usual.**
>
> **This is the owner's copy, not an agent's.** Phase 108's prompt and the Claude Design prompt both
> name `docs/design/free-tier-copy.md` as the single source for every user-visible string in this
> work — and **the file did not exist on disk.** No `docs/design/` directory on any branch, nothing
> in the history. It is one of two prescribed-but-unwritten files of Aug 21, 2026; the other is
> `docs/decisions/proposed-d2-d3-reversal-diff.md`, which phase 107 hit the same evening.
>
> It is reconstructed here from **two independent witnesses that agree**:
>
> 1. **The phase 109 (marketing) session's prompt carried the full text.** The owner pasted it there.
>    Sections 1–4 below are that transcription.
> 2. **The approved Claude Design bundle renders the same strings** —
>    `docs/App-Views/mobile-app-design-tiers-lock-cta/`, whose header states *"Every string is
>    verbatim from `free-tier-copy.md`"*. Every string phase 108 ships was checked against both.
>
> Neither witness is the file itself, so **a disagreement between them is a finding, not something to
> resolve quietly.** None was found in the strings; the two disagreements that exist are recorded
> under *Conflicts* at the bottom.
>
> **This file is a reconstruction and is not the source document.** If the owner's original ever
> resurfaces it wins over this, and over any agent's reading of it. A reader who finds this in the
> tree and treats it as the authority is making exactly the mistake this header exists to prevent.
>
> **Phase 108 authored nothing in sections 1–4.** Two strings it needed and could not draw from
> either witness are in *Proposed additions*, unshipped or clearly marked.
>
> Implemented in `ios/Rascal/Rascal/Subscription/MembershipCopy.swift`, which is the only file in the
> iOS lane holding any of these strings — so replacing this copy is a one-file diff that touches no
> view.

**Status:** owner-review pending. **This is the single source.** The Claude Design prompt and the
Lane B prompt both point here and are forbidden from inventing alternatives. If a string is needed
that is not in this file, the agent adds it to a *Proposed additions* section at the bottom and
reports it — it does not write it into a view.

Tokens: `{{PRODUCT}}`, `{{PRICE_MONTH}}` = `$5.99`, `{{PRICE_YEAR}}` = `$59.99`.

---

## The rules this copy is written under

Carried from `docs/decisions.md` and the standing product rules. An agent reviewing or extending this
copy checks against these before proposing anything.

1. **No guilt, no urgency, no counting.** No badges, no red dots, no "you've missed 4 missions", ~~no
   countdown on the trial~~, no "don't lose your archive". A locked card that accumulates a number is a
   streak wearing a padlock. **Amended Sep 3, 2026 by the owner, for one surface (phase 144):** the
   Settings membership card may state the day the trial ends and how many days that is — *"13 days
   left, until Sep 17, 2026"* — **from the server's own count**, never arithmetic on the phone, and
   only beside the date. Nowhere else, no push, no notice, no badge: the rest of this rule stands.
2. **Never "unlock", never "upgrade", never "premium" or "pro".** The word is **membership**. A person
   **joins**; they do not upgrade. The verb on the primary action is **Become a member**.
3. **The archive is never the thing being sold.** Membership buys *more of the day*. Everything a
   parent has already written or captured stays theirs, readable, exportable, free, forever. Any
   sentence that implies otherwise is wrong and must be reported rather than softened.
4. **The lock states inclusion, not deprivation.** "Included with membership" — not "Locked", not
   "Members only", not "Unlock this".
5. **Show the shape, never blur the content.** A locked card says what *kind* of thing it is (a photo,
   his voice, something to do together). It never blurs or teases prompt text. Hidden content behind
   frosted glass is a dark pattern and off-register for this product.
6. **The free tier is described positively and first.** "The daily question is always free" leads;
   what membership adds follows.

---

## 1 · The locked card on Today

Sits below the unlocked cards, above `waiting`. One card per locked slot — one on a weekday, two on a
weekend. Never a single summary card counting them.

**Weekday (`mission`, photo):**
- Eyebrow: `TODAY'S PHOTO MISSION`
- Body: `A picture of him, and the reason you took it.`
- Footer row: `Included with membership`

**Weekday (`mission_b`, video / voice / activity):**
- Eyebrow: `TODAY'S SECOND MISSION`
- Body: `His voice, a video, or something to do together.`
- Footer row: `Included with membership`

**Weekend third card** — the two above, both shown.

**Shared slots, when locked:**
- `weekly` → eyebrow `THIS WEEK'S MISSION`, body `A bigger one, once a week.`
- `monthly` → eyebrow `THIS MONTH'S MEASUREMENT`, body `How much of him has changed since last month.`
- `letter` → eyebrow `A LETTER TO HIM`, body `Sealed until he's old enough to read it.`

**Tap target:** the whole card. Opens the membership sheet. No secondary action, no dismiss — a
dismissible lock becomes a thing to dismiss every morning.

---

## 2 · The membership sheet

> **Reader's note, not copy — nothing in §§1–4 has been edited.** The bullet
> `Three on Saturdays and Sundays` below reads as though it contradicts §1's *"one card per locked
> slot — one on a weekday, two on a weekend"*. **It does not: §1 counts locked cards and §2 counts
> items in the day** — the free question plus those two missions. Confirmed independently by the
> approved design, whose artboard `1c` is titled *"The same weekend, member — three live, no locks"*
> and draws exactly three, and by phase 107's live server, which returns two locked mission slots at
> the weekend. The file was never ambiguous, only compressed. Recorded here as well as under
> *Conflicts* because this is where a reader trips on it.

Presented from a locked card, from Settings, and from the guardian-invite surface. Same sheet every
time.

**Title:** `The daily question is always free.`
**Subtitle:** `Membership is what fills in the rest of the day.`

**What membership adds** — a list, in this order, no icons competing with the terracotta:

- `A mission every day — a photo, a video, his voice, or something to do together`
- `Three on Saturdays and Sundays`
- `The monthly measurement, and letters you seal until he's old enough`
- `Video, and photographs without a limit`
- `His other parent, on the same archive`

~~**What stays free, always**~~ **Yours either way** — a quieter block beneath it, `inkMuted`.
**Revised Aug 26, 2026 by phase 125; all four strings owner-authored, approved Aug 26, 2026.**
The struck header and the three fragments below it are kept as the record of what shipped from
phase 108 until then, because `design-conformance-110.md` F12 and `reports/phase-124-preflight.md`
(at its line 38) quote them — **one report file, not two**.

- ~~`A question every day, forever`~~ → `A new question every day, with no limit and no countdown.`
- ~~`Everything you've already written or captured`~~ → `Everything you've already written and captured stays yours.`
- ~~`Search, and a full export of the whole archive`~~ → `Search the whole archive, and export all of it whenever you want.`

**The terminal full stops are deliberate.** The originals were fragments; the replacements are
sentences. **The header is sentence case here and stays that way in Swift** — the surface renders
it uppercased by text style rather than by content, so an uppercased literal would be a second
place for the casing to be decided.

**Price row:** annual preselected.
- Annual: `{{PRICE_YEAR}} a year` · caption `Two months free`
- Monthly: `{{PRICE_MONTH}} a month`

**Primary action:** `Become a member`
**Secondary:** `Not now` — plain text, `inkMuted`, never smaller than the primary's label size and
never greyed to near-invisibility.

**Footnote:** ~~`One membership covers the whole family — every child, both parents.`~~ →
`One price covers everyone in the house — every parent, every child.`
**Replaced Aug 26, 2026 by the owner's call**, reusing §7's row-3 sentence rather than authoring a
sibling for it. Same reason: *"both parents"* presumes a two-parent household. **It was not in
phase 125's list** and was left alone under that phase's match rule until the owner asked for it,
which is why it is recorded here separately from the eight.

**If StoreKit products cannot be fetched:** the price row is replaced by one `Notice` row —
`Membership isn't open yet. The daily question is, and everything you write is yours either way.`
The primary action is hidden, not disabled. Never a spinner that never resolves.

---

## 3 · Signup and the two weeks

Shown once, immediately after the first successful sign-in, before the first Today.

**Title:** `Two weeks, everything open.`
**Body:** `No card, nothing to cancel. After two weeks the daily question keeps going, free, and the
missions become part of membership.`
**Primary action:** `Start`

No countdown afterwards. No day-N reminders. No "your trial ends tomorrow" push.

**The one notice, on the first Today after the trial ends** — an inline `Notice` row, dismissible,
shown once and never again:
- `Your two weeks are up. The daily question keeps going, free, forever. The missions are part of
  membership whenever you want them.`
- Action: `See what's included` → opens the membership sheet. Dismiss: `Dismiss`.

---

## 4 · Strings that must not appear anywhere

Kept explicit so a review can grep for them.

`Unlock` · `Upgrade` · `Premium` · `Pro` · `Free trial ending` · `Don't lose` · `You've missed` ·
`Limited time` · `Only X left` · `Your archive will be` · `Members only` · `Locked` (as a label; the
visual state may still be called locked in code) · any streak, any count of skipped items, any
percentage complete.

---

## Proposed additions

*Agents append here rather than writing new strings into views.*

**1 · The pronouns, and this is the one that needs a decision rather than a string.**

**Every mission body, the letter slot and one whole sheet bullet are written for a boy** — *"A picture
of **him**"*, *"**His** voice"*, *"until **he's** old enough"*, *"**His** other parent"*. This app
renders pronoun tokens from the child's record, and a family with a daughter would be told *"A picture
of him"* on the first screen of an app about their specific child. `CLAUDE.md` is explicit and
overriding: *"Never write copy that assumes a child's gender — client-side strings are neutral too and
stay that way."*

**Phase 108 did not rewrite the copy and did not neutralise it.** It applied the prompt library's own
pronoun tokens, so that:

- a **`he/him`** child reads the owner's sentence **byte for byte**;
- every other child reads a correct one;
- the **membership sheet** renders against *no* child, which is they/them by construction — a
  household is not a child, and in a household with a boy and a girl any other choice is wrong for
  one of them.

The five strings, as implemented:

| Copy file | Shipped |
|---|---|
| `A picture of him, and the reason you took it.` | `A picture of {them}, and the reason you took it.` |
| `His voice, a video, or something to do together.` | `{Their} voice, a video, or something to do together.` |
| `How much of him has changed since last month.` | `How much of {them} has changed since last month.` |
| `Sealed until he's old enough to read it.` | `Sealed until {they_are} old enough to read it.` |
| `A LETTER TO HIM` | `A letter to {them}` (the `label` role uppercases it) |
| `…a photo, a video, his voice…` | `…a photo, a video, {their} voice…` |
| `…letters you seal until he's old enough` | `…letters you seal until {they_are} old enough` |
| `His other parent, on the same archive` | `{Their} other parent, on the same archive` |

**Two strings are not byte-identical even for a `he/him` child**, and this is the part to rule on:
*"until he's old enough"* renders as *"until he is old enough"*, because the token table has no
contracted form and **inventing a token is what this file forbids.**

**If the owner wants the literal masculine copy, it is one file.** If they want a sentence written for
a household rather than a child — e.g. `The other parent, on the same archive` — that is a copy
decision and belongs here rather than in a view.

**⚠️ This is a ruling on three surfaces, not one, and it is cheaper to see that before answering.**

| Surface | State |
|---|---|
| **This file / the iOS app** | Written for a boy; shipped tokenised, so a `he/him` child reads it verbatim |
| **The marketing site's tier, mission and membership copy** | **Already neutral** — `their voice`, `Their other parent`, `Letters you seal until they're old enough`, in the visible copy *and* in the `FAQPage` and `HowTo` JSON-LD. Zero gendered pronouns |
| **The marketing site's narrative voice** | **Says `he` six times** — five on the home page, one on `/how-it-works`: *"search 'what he was afraid of'"*, *"What is he pretending to be this week?"*, *"whether he was three or four"*. All pre-existing |

The site's one deliberate `her` — in the `/prompts` paragraph explaining that the tokeniser says
*her* to a family with a daughter — is doing its job and is not part of this.

**The app and the site's product copy already agree**, by two independent routes: the sheet renders
against no child, which is they/them by construction, and the site was written neutral. The open
question is the **narrative voice**, which is prose written for the one four-year-old this was built
for — a different category from a paywall string, and not obviously wrong. Found by the phase 109
session while checking the surfaces against each other.

**2 · A string for a slot or hint newer than the client.**

The server's `locked[]` carries `{slot, kind_hint}`, and both are open vocabularies — Lane A asks
clients to decode leniently so a sixth slot does not crash an older build. No source covers that case.
Phase 108 ships, as **the only authored strings on the card**:

- Eyebrow: `Another mission today`
- Body: `Something else to do together.`

They are deliberately shapeless, because the client genuinely does not know what the slot is. The
*visual* fallback is **not** authored — `design-system.md:291` already specifies neutral rendering for
an unrecognised kind and `AssignmentPresentation` already centralises it.

**3 · A one-line form of the lock, proposed by the design and not built.**

The design's artboard `1f` explored a single quiet row instead of cards and needed a one-line form,
flagging that it had none: *"A one-line form belongs in the file — proposed, not drawn:
`Missions are included with membership.`"* **The owner rejected `1f`** — *"we want to show the locked
missions always"* — so the row is not built and the string is **not rendered anywhere.** It is carried
in `MembershipCopy.membershipMissingAction` so the next person to want a compact lock finds the
proposal rather than writing a second one.

**4 · The Settings membership row — four status strings, added by phase 112 on Aug 22, 2026.**

**This file has never described the Settings card**, and the approved design does not draw one —
*"Settings"* appears in the bundle five times and every one is the tab-bar label. So the row that
reports what a household is on had no approved copy at all, while shipping since phase 37a.

The row is `Household`, and it can now give four answers:

| `access` | Answer | Note |
|---|---|---|
| `subscribed` | `Subscribed` | shipped since 37a, reproduced not authored |
| `trial` | `Everything open` | **the new string** |
| `free` | `Free` | shipped since 37a, reproduced not authored |
| absent / unrecognised / no household yet | `—` | shipped since 37a |

**Only one string is new, and it is derived from §3 rather than written.** §3's approved title is
*"Two weeks, everything open."* — `Everything open` is that phrase's second half, moved to a second
surface. **The owner chose it on Aug 22, 2026** from three candidates: `Trial`, `Two weeks`, and this
one. `Two weeks` was rejected as reading like a duration in a value row, which is one step from the
countdown rule 1 bans.

~~**What the row deliberately does not say.** No date, no day count, no "ends on". `trial_ends_at` is
decoded by the client and read by nothing, and a test now pins that the membership surface contains
no date arithmetic at all. A digit in any of these four answers fails the suite.~~ — **reversed Sep 3,
2026 by the owner (phase 144, §9 below).** The card now says both the day and the count, and
*Everything open* — the owner's Aug 22 pick — is retired: it was the owner's own first complaint,
*"makes no sense"*. The arithmetic test survives with its two `trial_ends_at` tokens removed: the
surface may read and format a server date and may never compute from one.

**Why `Everything open` and not the trial's *name*:** the row reports what the household *has*, not
what stage it is at. That is the same reason `Free` is not `Free tier` and why rule 2's *membership*
vocabulary is not violated by either — nobody is being told to upgrade.

**5 · An archive-scoped reassurance for the Settings card — resolved without a new string.**
**Struck Sep 3, 2026 by the owner (phase 144): *"The yours either way section can go completely."***
The block below still renders on the membership sheet and nowhere else; the paragraph is kept as the
record of why it was on the card from phase 112 to 144.

Phase 112 was asked to put the archive reassurance on the membership card **in every state**. This
file has no one-line form of it, and the file forbids an agent writing one. Rather than propose a
sentence, the phase renders §2's approved free block — **"What stays free, always"** then, **"Yours
either way"** since phase 125 revised all four strings on Aug 26, 2026 — the label and its three
lines, verbatim and in order, on the Settings card as well as in the sheet. Nothing was
authored, and the two surfaces now say the same three things in the same words.

**It renders for a subscribed household too**, which is deliberate: rule 3 is a promise to
everybody, and a reassurance shown only on the free tier reads as a sales argument rather than a
standing fact.

---

**6 · Four states phase 113 can now express and nothing renders, for want of a string.**

Phase 113 shipped `lapsed_at`, `plan`, `billing_retry` and `is_payer` on `GET /families/me`. Phase
112 **decodes all four and renders three of them nowhere**, because this file has no copy for them
and the file forbids an agent writing any. Each needs one decision, not a paragraph:

- **Free, lapsed (state 6).** `lapsed_at` now distinguishes a household that subscribed and stopped
  from one that never subscribed. **They currently read identically — both `Free`.** Whether they
  *should* differ is a product call: the honest argument for leaving them the same is that the free
  tier is the same tier either way, and rule 3 says the archive is never the thing being sold. **No
  string is proposed here**, deliberately — anything in this slot risks becoming the *"Your archive
  will be…"* shape §4 bans, in a friendlier voice.
- **Annual vs monthly (states 2 and 3).** `plan` is decoded. The row says `Subscribed` for both.
  Apple's own management sheet already shows the plan, which makes this a **fallback rather than a
  gap** — a string here would duplicate Apple's, and go stale if they change it. Proposed only if
  the owner wants the cadence on the card: `Subscribed — annual` / `Subscribed — monthly`.
- **Billing grace (state 7).** `billing_retry` is decoded and **gates nothing, by design** — the
  household is fully entitled and reads `Subscribed`, which is correct and must not change. The
  open question is whether to say anything at all. **Note the trap:** almost every natural sentence
  here — *"there's a problem with your payment"* — is an urgency state, and the tone rules ban
  those outright. If anything is wanted, it wants writing carefully rather than quickly.
- **Member, not the payer (state 4).** `is_payer` is decoded. On an explicit `false` the **Manage
  subscription row is hidden entirely** and nothing replaces it, because there is no approved
  sentence naming the other parent. That is the state most likely to read as a bug rather than a
  decision. Proposed, if the owner wants the row to speak: `Managed by the other parent.` — a
  `SettingsValueRow`, not an action, since there is nothing for this parent to tap.

**`is_payer` is null far more often than it is `false`**, and null keeps the Manage control. The
hidden state is reachable only when the server is certain, which today means a one-guardian
household — so the state above is rare now and becomes common only if the client ever starts
telling the server who transacted. See `blocked.md` §21.

---

---

**7 · The Settings membership card — four owner-authored strings, revised Aug 26, 2026 by phase
125.** Recorded here rather than only in Swift, because this file is the source of truth for these
strings and a Swift change without one is a divergence the next phase inherits as a mystery.
**All four were authored by the owner and approved Aug 26, 2026.** The struck values are what
shipped from **phase 37b** (`b7a45e3`, Aug 20, 2026) until then — not phase 112, which added the
*status row's* four answers and changed none of these four. `git log -S` against
`SubscriptionSection.swift` for each of the three checkable literals returns that one commit.

| # | Where | From | To |
|---|---|---|---|
| 1 | Status row **label** | ~~`Household`~~ | `Your household` |
| 2 | Membership action row, title | ~~`See the subscription`~~ | `See what membership includes` |
| 3 | Membership action row, subtitle | ~~`One price for the whole household — both parents, every child.`~~ | `One price covers everyone in the house — every parent, every child.` |
| 4 | Restore row, subtitle | ~~`Rarely needed — your subscription follows the household, not the phone.`~~ | `If you've paid before and this phone doesn't know it yet.` |

**Row 3's reason is not style.** *"both parents"* presumes a two-parent household; the replacement
does not. **The status *value* did not change** — `Everything open` and every other output of
`MembershipPresentation.settingsStatus(for:)` is §4 above and out of scope here. **The restore row's
*title* did not change either**: App Review 3.1.2(c) wants that control present and recognisable,
and renaming it is a rejection risk for no gain.

**A fifth string, added by phase 126 on Aug 26, 2026 and chosen by the owner from three
candidates.** A restore from Settings does not dismiss anything — the parent stays on the card they
were reading — so a row that spins and then stops is indistinguishable from one that failed. The
surface needed a sentence for a restore that *succeeded*, and there was none in this file. **The
rule was raised rather than quietly broken**: the phase wrote a placeholder, said so, and the owner
picked the wording.

| # | Where | String |
|---|---|---|
| 5 | Membership card, under the card, after a restore that found a membership | `Found it. Your membership is active.` |

It is `SubscriptionModel.restoreFound`, and it renders through the same coalesced line as the
not-found notice so the two can never appear together. **It is deliberately not `notice`**:
`SubscriptionTests.aSuccessfulRestoreIsNotSilent` asserts `notice == nil` on the found path, because
`notice` means *something went not-quite-right*.

**The same revision changed the free block in §2 above**, which the sheet and the card both render —
so those four strings moved on two surfaces at once. That is the intended consequence of §5's
decision to render one approved block in two places rather than write a second one.

### 8 · The purchase, reported on the Membership card — phase 140, Sep 3, 2026

**Reproduced, not authored, and recorded here so the owner can keep or reword them.** The sheet now
dismisses itself the moment Apple takes the money (the owner's request of Sep 2: *"close that view
and bring them back to the settings page and show the finishing"*), so the Membership card has to say
what the sheet used to hold open. The five sentences below shipped in `PaywallSheet` with phase 37b
on Aug 20, 2026 — two days before this file was reconstructed — and are in neither this file nor
`MembershipCopy`. Phase 140 moved them verbatim into `Subscription/PurchaseCopy.swift` so both
surfaces read one source; changing a word there changes it on both. The rule above is *"does not
write it into a view"*; the spirit is *the owner decides the words*, and this entry is how that
happens.

| # | Where | String |
|---|---|---|
| 8a | Sheet, and the card's offer-row slot, while Apple's sheet is up | `Talking to the App Store` |
| 8b | Sheet (rarely, behind a legal page), and the card's offer-row slot, while the server is told | `Finishing up` |
| 8c | Sheet only, after the server says so | `You're subscribed. Thank you.` / `Everything is shared with the household now.` |
| 8d | Sheet as two lines; under the card as one | `Your membership is being confirmed.` / `There's nothing else you need to do — it'll appear here shortly.` |
| 8e | Sheet as two lines; under the card as one | `This purchase needs approval.` / `Once it's approved, the app will notice on its own.` |

**The card says nothing extra on success.** Its status row already reads §4's `Subscribed` and the
Manage row appears — "the normal you have subscription view", in the owner's words — so 8c stays on
the sheet. A refused purchase renders the store's own sentence (`SubscriptionStoreError.userMessage`,
already shipped) under the card only if the parent swiped the sheet away without reading it.


### 9 · The Settings membership card, redesigned — phase 144, Sep 3, 2026

**Approved by the owner on Sep 3, 2026 from twelve rendered mockups**, after he asked for an overhaul
in his own words: *"Everything open makes no sense … See what membership includes is also super
confusing … The yours either way section can go completely."* The design is
`membership-card-redesign.md` beside this file; every string below is approved as written unless
marked, and lives in `MembershipCopy.Card`. `{date}` is the server's instant through
`DayHeaderText.dayAndMonth`; `{days}` is the server's `trial_days_left`. **Neither is arithmetic on
the phone.**

| id | Where | String | Status |
|---|---|---|---|
| S2 | Header eyebrow, every state | `Your household` | approved §7 row 1 |
| H1 | Headline, trial | `Free trial` | approved; replaces `Everything open` |
| H2 | Headline, free (never or lapsed) | `Free` | shipped since 37a |
| H3 | Headline, `plan: annual` | `Annual membership` | approved — *"Annual Membership please"* |
| H4 | Headline, `plan: monthly` | `Monthly membership` | approved — *"if they are monthly it should say that"* |
| H5 | Headline, subscribed with no plan on the wire | `Membership` | approved |
| H6 | Headline, granted | `Complimentary membership` | approved |
| H7 | Headline, unknown | `—` | shipped since 37a |
| D1 | Detail, trial | `{days} days left, until {date}. No card, nothing to cancel.` | approved (mockup 1B) |
| D1s | Detail, trial, last day | `One day left, until {date}. No card, nothing to cancel.` | built as spelled-out, so no constant carries a digit; owner to confirm |
| D1d | Detail, trial, an older server sending no count | `Until {date}. No card, nothing to cancel.` | approved (mockup 1A) |
| D1b | Detail, trial, no date either | `No card, nothing to cancel.` | §3's body, first sentence |
| D2 | Detail, free | `The daily question is always free.` | §2 title |
| D3 | Detail, subscribed, `auto_renew: true` | `Renews {date}` | approved |
| D4 | Detail, subscribed, `auto_renew: false` | `Expires {date}` | approved |
| D5 | Detail, subscribed, `auto_renew` unknown | `Paid through {date}` | approved |
| D5p | Appended to D5 where Manage is beneath | `Whether it renews is set in the App Store.` | approved |
| D6 | Detail, `is_payer: false`, appended | `Managed by the other parent.` | approved (mockup 4) |
| D7 | Detail, `billing_retry: true` | `The App Store couldn't take the last payment and will try again. Membership carries on in the meantime.` | approved (mockup 5) |
| D8 | Detail, granted, perpetual | `Everything a member has, with nothing to pay and nothing to renew.` | approved |
| D9 | Detail, granted with an end | `Everything a member has, until {date}. After that the daily question keeps going, free.` | approved |
| D10 | Detail, no household yet | `The app hasn't heard back from the server yet. It'll check again the next time you open it.` | approved |
| D11 | Detail, `access` this build cannot read | `This version of the app can't read your membership yet. Nothing is held back; an update will be able to show it.` | approved |
| R1 | CTA label | `Become a member` | §2 primary action |
| R2 | CTA detail, free and unknown | `Membership is what fills in the rest of the day.` | §2 subtitle |
| R2t | CTA detail, trial | `Keeps the missions going after the trial. You're charged when you join, not when it ends.` | approved |
| R3 | Manage label | `Manage subscription` | shipped |
| R4′ | Manage detail | `Change the plan or cancel in the App Store, from the Apple Account that pays for it.` | approved; replaces `Change the plan or cancel, in the App Store.` |
| R4r | Manage detail, billing retry | R4′ + ` The payment method is in that account's settings.` | approved |
| R5 | Restore label | `Restore a purchase` | shipped; Review 3.1.2(c) |
| R6 | Restore detail | `If you've paid before and this phone doesn't know it yet.` | §7 row 4 |

**Retired from the card**: `Everything open`, `Subscribed`, `See what membership includes`, the
footnote *"One price covers everyone in the house…"* (still the sheet's), and *Yours either way*
with its three lines (still the sheet's). **Moved into the card**: the late and Ask-to-Buy sentences
(§8d, §8e) render as a plain row in the CTA's slot rather than under the card, and *Become a member*
is not shown above them.

**Restore appears only where a restore could find something** — trial, free, and a household the
server has not answered for — and is hidden for every member state, because for a member it can
only re-read the answer already on the card. The paywall keeps its own Restore and its Terms and
Privacy links for App Review.

## Conflicts

**1 · The design recommended treatment A; the owner chose C.** Artboard `1d` rendered four locked-card
treatments and picked **A** (`surface`, border, no shadow), arguing against C by name: *"`terracottaSoft`
at any opacity is the fill a **live** mission wears. Washing it makes the locked card look like a live
mission rendering badly."* The owner read that and chose **C** — `terracottaSoft` at 45%, border,
resting shadow. **C shipped.** The argument against it is recorded because it is the strongest thing
anyone has said about what shipped, and it should outlive the decision. Mitigated in code: the fill is
composited over canvas in two layers so it resolves to `#FCF4EC`, measurably lighter and pinker than a
live mission's flat `#FBEDE2`, and `inkMuted` on it measures 4.94:1.

**2 · §2's `Three on Saturdays and Sundays` reads oddly against §1's "two on a weekend"**, and the
reconciliation is confirmed rather than inferred: §1 counts *locked mission cards* (two at the
weekend) and §2 counts *items in the day* (the free question plus those two). The design's artboard
`1c` is titled *"The same weekend, member — three live, no locks"* and draws exactly three. Lane A's
live server confirms two locked mission slots at the weekend. **No change needed to either line.**

**3 · The approved design omits two App Review requirements.** Neither the restore control nor the
Terms/Privacy links appear on any sheet artboard, and the plan row draws price-and-period with no
product title. All three are Guideline 3.1.2 requirements and **cannot be designed away**, so all
three ship. The artboards are drawing the sheet's content and stopping; a restyle that read them
literally would have deleted a control whose absence is a rejection.

**4 · The live marketing site's contradiction is resolved.** It promised the un-reversed D2 in seven
places including two JSON-LD blocks. **Phase 109 has rewritten them all** — pricing, FAQ, the home
page, two comparison pages, the prompts page and `site-content.md`. Recorded here because this file is
where somebody will look when the app and the site disagree.
