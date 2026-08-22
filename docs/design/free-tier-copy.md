# Free-tier copy

> ⚠️ **This file was written by phase 108, not by the owner, and it is unreviewed.**
>
> Phase 108's prompt names this file as the verbatim source for every user-visible string in the
> locked board, the membership sheet and the trial welcome — and **the file did not exist.** No
> `docs/design/` directory, nothing in any branch, nothing in the history. It is the second
> prescribed-but-unwritten file of Aug 21, 2026; the other is
> `docs/decisions/proposed-d2-d3-reversal-diff.md`, which phase 107 hit the same evening.
>
> Rather than block an overnight run, phase 108 authored the strings below and **quarantined every
> one of them in a single Swift file — `ios/Rascal/Rascal/Subscription/MembershipCopy.swift`** — so
> that replacing this copy with the owner's is a one-file diff and touches no view.
>
> **Nothing here is a decision.** Where a string had to assert something about the product, it was
> derived from a settled decision rather than invented, and each one names its source below. Where
> no decision covered it, it is marked **(invented)** and is the first thing to rewrite.

**Product name:** Vellum. Never abbreviated, never possessive in a headline.

---

## Rules this copy is written under

The first four are **behavioural**, not verbal. They constrain what gets built, not only what gets
said, and a view that violates one is a defect even if every string on it is correct.

1. **No badge, no red dot, no count of locked or skipped items, anywhere, ever.** Not on the tab
   bar, not on a card, not on the Settings row. A count of things you did not buy is a scoreboard,
   and this product has no scoreboards. Follows `design-system.md`'s *"4 waiting is a count, not an
   accusation"* and extends it: a locked item is not even a count.

2. **No countdown on the trial, and no "your trial ends soon" notification.** `trial_ends_at` is on
   the wire and the client decodes it. **It is used for nothing.** No day counter, no progress bar,
   no push. A parent who is enjoying the app should not be watching a clock run out on it.

3. **A locked card is not dismissible.** No swipe-to-skip, no "not for us", no ✕. A lock you can
   dismiss becomes a thing to dismiss every morning, which is a chore this product invented for
   itself. It is also not *skippable* in the sense the board means: it was never offered, so there
   is nothing to decline.

4. **The words `Unlock`, `Upgrade`, `Premium` and `Pro` appear nowhere in a user-visible string.**
   Not in a button, not in a header, not in an accessibility label. *Unlock* is wrong twice over —
   it implies the archive is locked, which D3 says it never is, and the app already uses "unlock"
   for a sealed letter opening at an age, which is a promise rather than a purchase.

And, inherited from `design-system.md`'s copy rules and applying in full here:

5. **Never scold, and never imply falling short.** A parent on the free tier has done nothing wrong.
   No red, no urgency, no "you're missing out".
6. **Say what is true about money.** Every price, cadence and trial length on screen comes from
   StoreKit, never from this file. The `{{PRICE_*}}` tokens below exist so copy can be *reviewed*;
   a build that renders one has a bug.
7. **State the free tier plainly, never as fine print.** It is the reason this sheet is a door and
   not a wall.

---

## The tokens

Same convention as the marketing site's `site.config.json`, and the same values, so the two agree by
construction rather than by luck.

| Token | Value | Source |
|---|---|---|
| `{{PRICE_YEAR}}` | `$59.99` | D1, and `Rascal-Marketing/site.config.json` |
| `{{PRICE_MONTH}}` | `$5.99` | D1, ditto |
| `{{FREE_PHOTOS}}` | `100` | D2 — *"100 photos lifetime, not per month"*, unchanged by the reversal |
| `{{TRIAL_DAYS}}` | `Fourteen` | D1 — *"14-day trial"* |

**The price tokens are for copy review only.** In the app, `PlanCopy.priceLine(_:)` builds every plan
row from `Product.displayPrice`, and `AnnualSaving.describe(_:)` computes the saving from the two
real prices. A literal would be wrong in every other currency, wrong the day a tier changes, and
wrong in a way no test catches — the string renders perfectly.

---

## 1 · The locked card

One card per entry the server returned in `locked[]`, below the live prompts and above `waiting`.

The card **says nothing about the prompt it is withholding**, because the server sends nothing about
it: `locked[]` carries `{slot, kind_hint}` and no body, title or theme. That is deliberate on the API
side and right on this side too — a teaser for a prompt you cannot answer would burn the 180-day
cooldown on it and leak the library D7 calls the one asset worth stealing.

So the card names **the shape of the thing**, not the thing.

| `kind_hint` | Card body | Glyph |
|---|---|---|
| `photo` | `A photo mission` | `camera` |
| `mission` | `A mission to go and do` | `figure.walk` |
| `weekly` | `This week's prompt` | `calendar` |
| `monthly` | `This month's prompt` | `calendar` |
| `letter` | `A letter to write` | `envelope` |
| *anything else* | `Another prompt today` | `sparkles` |

**Footer row, every card, verbatim:**

```
Included with membership
```

Not "included **in**". *With* is the household reading: one membership, everyone it covers.

**Accessibility label** — the body, then the footer, then what happens on tap:

```
{body}. Included with membership. Opens membership.
```

**(invented)** — every string in this section. Nothing in `decisions.md` specifies locked-card copy,
because until Aug 21 there were no locked cards. The bodies are written to be true of any prompt in
that slot, since the card cannot know which prompt it is.

---

## 2 · The membership sheet

Order is fixed: **title · subtitle · what membership adds · what stays free · plan selector ·
primary · secondary · footnote.**

### Title and subtitle, by where it was opened from

**From a locked card:**

```
The rest of the day
```

```
The daily question is always free. Membership adds the other half of the board —
the missions, the weekly and monthly prompts, and the letters.
```

**From Settings:**

```
A membership for the household
```

```
One membership covers everyone who keeps this archive — both parents, every child,
one price.
```

**From the guardian invite** — *carried over verbatim from the shipped `SecondParentUpgradeSheet`
and `PaywallSheet.Context.secondParent`. Do not rewrite; it is the accurate thing to say to somebody
who has just tried to add the other parent, and a second voice for one product is worse than a
slightly older sentence.*

```
Both of you, one archive
```

```
A membership shares this archive with the other parent. You keep the same children,
the same timeline and the same moments — and each of you gets your own prompts every
day, so you are not answering the same question twice.
```

> **Conflict, recorded rather than silently fixed:** the shipped string says *"A subscription
> shares this archive"*. Phase 108's prompt asks for the sheet to be called a **membership**
> throughout, and the product's own words elsewhere — the App Store subscription group is
> `Vellum Membership`, the Settings card is `Membership` — agree. The word is changed to
> *membership* in the two carried-over sentences and nowhere else. Flagged because the prompt said
> the second-parent copy is verbatim.

### What membership adds

Section label:

```
What membership adds
```

Rows, in this order:

```
The rest of today's board — the missions, and the small things to go and do
Every child you add, at the same price
Both parents, each with their own prompts every day
Photos without a limit, and video
```

Sourced: rows 1 and 4 from **D2 as amended Aug 21, 2026** — *"What moved behind the paywall is the
doing half of the day: `mission` (photo), `mission_b` (video/audio/activity), and the `weekly`,
`monthly` and `letter` slots"*, plus the untouched *"no video"* and *"100 photos lifetime"* clauses.
Rows 2 and 3 from **D4** — *"the subscription unit is the household"* — and from the Aug 17 decision
recorded against open item 11 that **the free tier does not include a second guardian**.

### What stays free

**This block gets real space.** It is set in `inkMuted` at reading size, not at metadata size, and it
is placed **above** the plan selector, not below it. It is the reason this sheet is a door and not a
paywall, and compressing it into a footnote is the specific failure this note exists to prevent.

Section label:

```
Free, always
```

```
The daily question, every day, forever. Unlimited writing and did-it entries. Voice
recordings up to two minutes. {{FREE_PHOTOS}} photos.

And everything already in your archive stays exactly as it is — readable, searchable,
and yours to export in full, always, whether or not you ever pay us.
```

Sourced, sentence by sentence, from **D3 as amended Aug 21, 2026**: *"the archive is never locked.
The day is… A free household keeps unlimited text and `did_it` entries, the 100-photo lifetime cap,
full export, full-text search, and **every entry it already has** — nothing it has written ever
becomes unreadable, unexportable or unsearchable because a subscription ended."*

The second paragraph is the one to defend if this sheet is ever cut for length. D3's operative test
is *"if a change would make an existing entry unreadable, unexportable or unsearchable on a free
tier, it is wrong"* — and this is where the product says that out loud to the person it is about.

### Plan selector

Two rows, **annual preselected**, per D1. Not a segmented control.

Every string on both rows is built by `PlanCopy.priceLine(_:)` from the StoreKit product. For copy
review only, the annual row reads approximately:

```
{{TRIAL_DAYS}} days free, then {{PRICE_YEAR}} a year
Two months free
```

and the monthly row:

```
{{TRIAL_DAYS}} days free, then {{PRICE_MONTH}} a month
```

`Two months free` is **computed** by `AnnualSaving.describe(_:)` — twelve monthlies against the
annual price — and is not a literal. It is shown only when the arithmetic actually supports it, and
in a storefront where annual is not cheaper it is correctly absent. D1's *"annual is exactly two
months free"* is the intent; the arithmetic is the authority.

### Primary action

Full-width terracotta, at the bottom. The label comes from `PlanCopy.buyLabel(_:)` and depends on
whether Apple would actually grant the trial:

```
Start the free trial      ← when the product carries a trial and this account is eligible
Subscribe                 ← when it does not
```

Unchanged from the shipped implementation, and deliberately so: it promises a trial only when there
is one to promise.

### Secondary action

Directly beneath the primary, plain text, same label size, **not greyed toward invisibility**:

```
Not now
```

> **Conflict, recorded:** the shipped string is `Not just now`. Phase 108's prompt specifies
> `Not now`. The prompt wins per its own gate. The two are equivalent in register and this is a
> one-word change; it is noted only because the shipped one was written deliberately.

Accessibility hint, unchanged from shipped:

```
Closes this and changes nothing
```

### Footnote

```
Billed through the App Store. Cancel any time in Settings on your iPhone — two taps,
like any other subscription.
```

**(invented)**, but every clause is load-bearing and sourced: the marketing site's pricing and FAQ
pages both say *"Settings on your iPhone, two taps, like any other subscription. Apple handles it and
we don't get to make it hard."* This is the same promise, shortened.

Terms of Use and Privacy Policy links stay exactly as shipped — App Review requires both on a
paywall, and `LegalLinks` already renders them absent rather than dead when a build has no URL.

### When products cannot be loaded — **the normal case, not the error case**

`api-contract.md` §37a records that **no subscription product exists in App Store Connect and no
sandbox transaction has ever been made.** So this is what the sheet shows today, on every device, and
it is designed as the ordinary state.

**The plan selector is replaced by one `Notice` row, and the primary action is hidden — not
disabled.** A disabled button is a thing to keep tapping.

Notice text:

```
Memberships aren't available just yet. Nothing about your archive has changed, and
the daily question is free either way.
```

**(invented.)** Two things it deliberately does not do: it does not apologise, and it does not blame
the network — the client genuinely cannot tell an empty product list from a dropped connection, so it
says what is true of both. The second sentence is there because the first, alone, reads as a fault.

**Never a spinner with no terminal state.** Loading times out into this.

---

## 3 · The trial welcome

One screen, once, after first successful sign-in, before the first Today. **No illustration of a
child, no stock photography, no progress dots, no carousel.**

Title:

```
{{TRIAL_DAYS}} days, everything included
```

Body:

```
Every prompt is open for the next {{TRIAL_DAYS_LOWER}} days — the daily question, the
missions, the weekly and monthly ones, the letters.

After that the daily question keeps coming, free, forever. Nothing you write or keep
in these {{TRIAL_DAYS_LOWER}} days is ever taken away.
```

Primary action:

```
Start
```

`{{TRIAL_DAYS_LOWER}}` is `{{TRIAL_DAYS}}` lowercased — "fourteen" mid-sentence. Listed as its own
token so a reviewer changing the number changes it in one place.

**(invented.)** The second paragraph is the important one and is D3's amended promise said in
advance, at the only moment a parent is deciding whether to trust the app with eighteen years.

---

## 4 · The post-trial notice

An inline `Notice` at the top of Today, shown **once**, on the first board after `access` flips from
`trial` to `free`. Dismissible. Never returns, whether it was dismissed or merely seen.

```
Your {{TRIAL_DAYS_LOWER}} days are up. The daily question is yours free, forever —
and everything you kept is still here.
```

Dismiss control, terracotta, per the existing Notice:

```
Dismiss
```

**(invented.)** It states a fact and then immediately says what is still true, because the fact on
its own is a loss and the sentence would be scolding without its second half. **It does not link to
the membership sheet** — a notice that sells is a nag, and the locked cards below it are already the
honest, permanent affordance.

---

## Proposed additions

*Strings phase 108 needed that this file did not have when the phase ran. Everything in the sections
above was authored by phase 108 too, so at the time of writing this section is a formality — it
exists so that once the owner rewrites the sections above, anything a later phase needs lands here
instead of being written into a view.*

Nothing outstanding. Every string phase 108 required is specified above and implemented in
`MembershipCopy.swift`.

---

## What is deliberately absent

- **Any sentence about what a free household "loses".** It loses nothing. Missions stop being
  *offered*; nothing is taken back. D3's amended distinction — *"between withholding an offer and
  taking back a thing somebody owns"* — is the whole argument and is why no string here uses "lose",
  "expire", "revoke" or "no longer".
- **Any count.** Of locked cards, of days, of photos remaining. See rule 1 and rule 2.
- **Any second-person failure.** No "you haven't", no "you're missing".
- **A restore-purchases string**, because the shipped one is already right and is not a phase 108
  concern: *"Restore a purchase"*, and on finding nothing, *"Nothing has arrived yet. If you
  subscribed on another device, it can take a moment to appear."* — which is careful about a thing
  worth being careful about: it makes no claim about what Apple holds.

---

## Known conflict with the live marketing site

Recorded here because this file is where somebody will look when the two disagree, and it is not
phase 108's to fix — **phase 109 is the marketing lane.**

`Rascal-Marketing` is built and deployed, and it currently promises the **un-reversed** D2 in four
places:

| File | Claim |
|---|---|
| `src/pages/pricing.html` | Feature table: *"Daily question and mission — **Every one, forever**"* for **both** tiers |
| `src/pages/pricing.html` | *"Is the free tier a trial? **No. It has no end date and no countdown.** Every question and every mission is uncapped on it, forever."* |
| `src/pages/faq.html` | *"Is free really free? Yes, and **it isn't a trial** — it has no end date. **Every question and every mission, forever.**"* |
| `src/pages/faq.html` | The same claims again inside a **JSON-LD `FAQPage` block** — machine-readable, and indexable |

Every one of those is contradicted by phase 107's gating and by this file. The JSON-LD is the one
worth acting on first: it is a schema.org claim a search engine may already be surfacing.
