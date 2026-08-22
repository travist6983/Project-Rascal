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

1. **No guilt, no urgency, no counting.** No badges, no red dots, no "you've missed 4 missions", no
   countdown on the trial, no "don't lose your archive". A locked card that accumulates a number is a
   streak wearing a padlock.
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

**What stays free, always** — a quieter block beneath it, `inkMuted`:

- `A question every day, forever`
- `Everything you've already written or captured`
- `Search, and a full export of the whole archive`

**Price row:** annual preselected.
- Annual: `{{PRICE_YEAR}} a year` · caption `Two months free`
- Monthly: `{{PRICE_MONTH}} a month`

**Primary action:** `Become a member`
**Secondary:** `Not now` — plain text, `inkMuted`, never smaller than the primary's label size and
never greyed to near-invisibility.

**Footnote:** `One membership covers the whole family — every child, both parents.`

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

---

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
