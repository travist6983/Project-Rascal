# The Membership card in Settings — the approved design (phase 144)

> **Provenance.** Written Sep 3, 2026 by a four-design judge panel, an adversarial critique and a
> revision, against `origin/main` at `efd8e39`; then rendered as twelve mockups and **approved by
> the owner the same day from those mockups**, with three rulings that override the text below
> where they differ:
>
> 1. **The trial line shows both the day count and the date** — *"I like the date count but both
>    is good idea."* The count is the server's `trial_days_left`, never arithmetic on the phone.
>    Section 5's recommendation of the date alone is therefore superseded, and copy rule 1 is
>    amended for this one surface (see `free-tier-copy.md`).
> 2. **The paid headline is the plan noun** — *"Annual Membership please and if they are monthly it
>    should say that."* Open decision 2 is closed that way; "Subscribed" is retired.
> 3. **Billing retry renders as drawn** (mockup 5). Open decision 4 is closed that way.
>
> One string moved in the build: the singular trial line is `One day left, until {date}.` rather
> than `1 day left`, so no authored constant carries a digit and the singular reads as a sentence.
> Everything else in the string table is what shipped. The mockups the owner approved are the
> phase's screenshots; the implementation is `ios/Rascal/Rascal/Subscription/` and the API half
> is `api/src/rascal/services/membership.py` and `services/guardians.py`.

# Membership card, Settings: the final design

Source of truth for this document: `origin/main` at `efd8e39` (Sep 3, 2026). Every citation below was read from that tree, not from memory. Revised Sep 3 after the three-lens critique; the findings that were not applied as written are answered in the appendix.

## 1. What was wrong

The status row answered "what are we on?" with a mood: "Your household · Everything open" names neither the trial nor when it ends, and a parent reading it for the first time has no idea whether they are paying. The action row named a reading task ("See what membership includes") rather than a decision, and it was shown to a household that already had everything (a granted one, until phase 141 hid it). "Restore a purchase" sat under every state, including a household the server already calls subscribed, where the only thing it can say afterwards is what the row above it already said. And "Yours either way" took half the card to make a sales argument on a surface whose only job is to report.

## 2. The organising idea

The card is a receipt. One `SettingsCardHeader` says, in a noun, what the household is on today ("Free trial", "Free", "Annual membership", "Complimentary membership"), with the one dated fact the server sent underneath it, formatted and never counted. Beneath the header there are only the rows that can change that answer: "Become a member" for a household nobody is paying for, "Manage subscription" for one somebody is, "Restore a purchase" only where a restore could find something. A granted household gets the header and nothing else. Every word maps off `GET /v1/families/me` through a pure function of `FamilySummary` and `PurchasePhase`, exactly as `settingsStatus(for:)` and `settingsAction(for:purchase:)` do today; nothing on the surface does arithmetic, reads StoreKit, or decides entitlement (D5, D9).

**The header detail is a sentence or two, never a paragraph.** `SettingsCardHeader` is specified as "headline at card title, one `metadata` detail line" (`design-system.md:540`; `SettingsRow.swift:96`, 13pt `inkMuted`). Every detail below fits that slot: the longest, D7, is two short sentences. Anything that wanted a third sentence has been moved to the row that owns it or dropped; nothing here asks for a body-size detail role.

**How this was assembled.** The spine is the platform-idiom design, which two of the three judges ranked first (the parent judge and the engineer). The rules judge ranked it last, and every objection that judge raised was a fixable defect rather than an argument against the shape, so each is fixed below: "Free trial" over "Ends {date}" (rewritten as "Until {date}"), the offer row under an unrecognised `access` (kept, and now for a stated reason: the offer follows `isMember`, the predicate the sheet's own buy button uses), the retry variant of the Manage row that promised to update the card (dropped; the retry variant that survives only names where the payment method lives), the "Previous membership" row (made optional, not recommended), the wash on a restore (no wash anywhere). Where the judges disagreed with each other:

- **Eyebrow.** "Your household" (owner-approved, §7 row 1) rather than cta-first's state-word eyebrow. Sided with the rules judge: the state belongs in the headline at `cardTitle`, not in the smallest type on the card.
- **Trial detail.** The engineer wanted status-first's "Until {date}. No card, nothing to cancel."; the parent judge wanted that plus §3's "After that…" sentence. The engineer's version, because the detail slot is one line and the after-story now belongs to the CTA row, where it is the sales sentence rather than the receipt (R2t). "Until" rather than "Ends", because the rules judge is right that "Free trial" directly over "Ends…" is the banned phrase in two lines.
- **Not the payer.** A sentence in the header detail ("Managed by the other parent.", copy-first and status-first) rather than platform-idiom's "Paid by · The other parent" value row, which the parent judge called the clearest of the four. Sided against the parent judge because the value row is the one element that wraps badly at AX3 (platform-idiom's own edge-case note) and because one component in every state is worth more than one clearer label.
- **Billing retry.** The rules judge wanted platform-idiom's two sentences and nothing else; the parent judge wanted copy-first's clause about updating the card. Both, split by row: the header carries the fact and the reassurance (D7), and the Manage row — the only thing to tap — carries where the payment method actually lives (R4r), because a parent whose card is failing will tap the one action on the card and must not find the wrong place. The contract says the field exists "so a client can offer to fix a card"; the offer is on the row, not in the header.
- **Subscribed on today's API.** A bare "Annual membership" header rather than the parent judge's graft of "Renews automatically until cancelled." Sided with the rules judge and the engineer: that is a product statement on the paywall, and on a status card it is a per-household claim the server has no auto-renew signal to back — until the API half lands, when it has an exact one (§7).
- **No household yet.** Keep the shipped "—" with the offer and Restore rows (engineer) rather than "Loading…" with no rows (rules judge), and give the dash a sentence (D10) that is true both while the first read is running and after it has failed, because the pure function cannot tell those apart. `loadHousehold()` is `try? await readHousehold()`, so a failed first read leaves `household` nil with no retry until the next foreground; "Loading…" would sit there indefinitely, and "—" is the approved word for not-known.
- **Restore during a purchase.** Visible but disabled (cta-first; all three judges), not removed. Enabled again in `.late` and `.awaitingApproval`, where it is the one control that can nudge the server.
- **Free, lapsed.** Identical to free (rules and parent judges); the engineer's "Previous membership" row is kept as an owner option only.
- **API field name.** `expires_at`, the name `admin_metrics.py:1064` already serialises for this column (all three).

## 3. The card, state by state

Legend: `SSH` = `SettingsSectionHeader("Membership")`; `SCH` = `SettingsCardHeader(eyebrow: "Your household", headline:, detail:)` with `isActive: false` in every state and no counter; `SAR` = `SettingsActionRow(label:, detail:)`; `DIV` = `SettingsDivider`. Eyebrow renders small caps `inkMuted`; headline `cardTitle` `ink`; detail `metadata` `inkMuted`. `{date}` is `DayHeaderText.dayAndMonth(serverDate)`, the formatter `DeleteAccountSheet.swift:138` already uses for a dated commitment: `.dateTime.day().month(.abbreviated).year()` (`Formatting.swift:102`), locale-ordered, so "17 Sep 2026" on a UK device and "Sep 17, 2026" on a US one. The mockups use the UK form. Under every card, unchanged: the one optional `inkMuted` metadata line, `restoreConfirmation ?? notice ?? purchaseLine(purchase)`.

### 3.1 Trial

```
MEMBERSHIP ──────────────────────────────────  SSH
┌────────────────────────────────────────────┐
│ YOUR HOUSEHOLD                             │  SCH eyebrow
│ Free trial                                 │  SCH headline
│ Until 17 Sep 2026. No card, nothing to     │  SCH detail (D1)
│ cancel.                                    │
├────────────────────────────────────────────┤  DIV
│ Become a member                            │  SAR (terracottaDeep) → PaywallSheet
│ Keeps the missions going after the trial.  │  SAR detail (R2t)
│ You're charged when you join, not when it  │
│ ends.                                      │
├────────────────────────────────────────────┤  DIV
│ Restore a purchase                         │  SAR, isBusy: isRestoring
│ If you've paid before and this phone       │  SAR detail
│ doesn't know it yet.                       │
└────────────────────────────────────────────┘
```

Condition: `access == "trial"`. Nothing else is read for the headline: `tier` is `free` by the contract's invariant and `entitlement_source` is consulted only to detect `grant`, so a pre-121 server (no `entitlement_source`) renders this state exactly the same. Date from `trial_ends_at`; if it is null (defensive only, a 107+ server always sends it with `access: trial`) the detail is D1b.

The CTA detail is the trial's own (R2t) because the header two lines above says the household already has everything: "Membership is what fills in the rest of the day" reads as false on a full board, or as "membership starts after the trial", and the second reading is the dangerous one — Apple grants no introductory offer (D1 amendment), so tapping "Become a member" on day three charges today and the remaining days are not carried over. The row that sends a parent into that charge is the row that has to say so.

Strings: H1 proposed; D1 first clause proposed, second sentence §3's approved body verbatim; R2t proposed; R1, R6 existing-approved; R5 shipped.

### 3.2 Free, never subscribed

```
┌────────────────────────────────────────────┐
│ YOUR HOUSEHOLD                             │  SCH
│ Free                                       │
│ The daily question is always free.         │
├────────────────────────────────────────────┤
│ Become a member                            │  SAR → PaywallSheet
│ Membership is what fills in the rest of    │
│ the day.                                   │
├────────────────────────────────────────────┤
│ Restore a purchase                         │  SAR
│ If you've paid before and this phone       │
│ doesn't know it yet.                       │
└────────────────────────────────────────────┘
```

Condition: `access == "free"`, `lapsed_at == null`. Also the fallback for `access` absent (a pre-107 server) with `tier == "free"`.

Strings: H2, H7 shipped since 37a and reproduced (§4 rows); D2, R1, R2, R6 existing-approved; R5 shipped. The header and the CTA detail are the sheet's title and subtitle, in the owner's order: the free tier first, membership second (rule 6).

### 3.3 Free, lapsed

Renders byte-identical to 3.2. `lapsed_at` stays decoded and unrendered. The free tier is the same tier either way, the copy file's §6 declined to write a lapse sentence because anything in that slot drifts toward the "Your archive will be…" shape, and the only approved sentence that would help ("Everything you've already written and captured stays yours.") is line 2 of the block the owner asked to remove. Option for the owner, not recommended: one `SettingsValueRow("Previous membership", "Ended {date}")` between the header and the CTA, from `lapsed_at`.

### 3.4 Subscribed, payer or payer unknown; annual and monthly

With the API half (`expires_at` and `auto_renew`, §7):

```
┌────────────────────────────────────────────┐
│ YOUR HOUSEHOLD                             │  SCH
│ Annual membership                          │  ("Monthly membership" for plan monthly;
│ Renews 17 Sep 2027                         │   "Membership" for plan null/unrecognised)
├────────────────────────────────────────────┤
│ Manage subscription                        │  SAR → .manageSubscriptionsSheet
│ Change the plan or cancel in the App       │  SAR detail (R4′)
│ Store, from the Apple Account that pays    │
│ for it.                                    │
└────────────────────────────────────────────┘
```

Detail by `auto_renew`: `true` → "Renews {date}"; `false` → "Expires {date}"; `null` or absent → "Paid through {date}. Whether it renews is set in the App Store." (D5 + D5p). With today's API (no `expires_at`), the header has no detail line:

```
┌────────────────────────────────────────────┐
│ YOUR HOUSEHOLD                             │  SCH, detail: nil
│ Annual membership                          │
├────────────────────────────────────────────┤
│ Manage subscription                        │  SAR
│ Change the plan or cancel in the App       │
│ Store, from the Apple Account that pays    │
│ for it.                                    │
└────────────────────────────────────────────┘
```

Condition: `tier == "subscribed"`, `is_payer ∈ {true, null}`, `billing_retry == false`. Annual and monthly differ by one word in the headline; `is_payer` true and null render identically (`mayManageSubscription` is `!= false`, unchanged).

**`is_payer` null is the common case, not the edge**, and this row is where that matters. In a two-guardian household Apple's `appAccountToken` carries the family, never the user, so the server cannot tell the parent who bought it from the parent who was invited; both read null and both get this row. On the invited parent's phone Apple's sheet lists no Pocket Chronicle subscription. The row's detail is therefore the only thing that can say where the sheet works: R4′ names the Apple Account that pays, so the parent who taps it and finds nothing has been told why before they tapped. The shipped R4 ("Change the plan or cancel, in the App Store.") is what renders if the owner declines the change. No "Become a member", no Restore.

Strings: H3, H4, H5, D3, D4, D5, D5p, R4′ proposed; R3 shipped (`SubscriptionSection.swift:63`); R4 shipped (`:64`) and proposed to change.

### 3.5 Subscribed, not the payer

```
┌────────────────────────────────────────────┐
│ YOUR HOUSEHOLD                             │  SCH, the whole card
│ Annual membership                          │
│ Renews 17 Sep 2027. Managed by the other   │  date line (when present) + D6
│ parent.                                    │
└────────────────────────────────────────────┘
```

Condition: `tier == "subscribed"`, `is_payer == false` (explicit). Nothing to tap: Apple's sheet on this device would not list the subscription, there is nothing to sell, nothing to restore. On today's API the detail is D6 alone. With `auto_renew` null the date line is D5 without the pointer ("Paid through 17 Sep 2027. Managed by the other parent."): the pointer is about the App Store this parent cannot reach.

Strings: D6 proposed (first proposed in §6, never approved).

### 3.6 Billing retry

```
┌────────────────────────────────────────────┐
│ YOUR HOUSEHOLD                             │  SCH, plain surface, no wash
│ Monthly membership                         │
│ The App Store couldn't take the last       │  D7 replaces the date line entirely
│ payment and will try again. Membership     │
│ carries on in the meantime.                │
├────────────────────────────────────────────┤
│ Manage subscription                        │  SAR, retry detail (R4r)
│ Change the plan or cancel in the App       │
│ Store, from the Apple Account that pays    │
│ for it. The payment method is in that      │
│ account's settings.                        │
└────────────────────────────────────────────┘
```

Condition: `tier == "subscribed"`, `billing_retry == true`, `is_payer ∈ {true, null}`. The date line is displaced whatever the ledger holds — and the server sends `expires_at: null` during a retry anyway (§7), so the client never compares a date to a clock and never renders the date a renewal failed on. The header says what happened and that nothing is withheld; the row, which is the only thing to tap, says where the plan lives and, separately, where the payment method lives, because Apple's manage-subscriptions sheet does not reach a payment field and a sentence that sent the parent there would be the over-promise everyone agreed to drop.

With `is_payer == false` this state renders as 3.5 (D6, no rows, no date line): the retry sentence is an offer to fix, and there is nothing this parent can fix. If the owner prefers silence, delete D7 and R4r and this state renders as 3.4, which is what ships today.

Strings: D7, R4r proposed.

### 3.7 Granted

```
┌────────────────────────────────────────────┐
│ YOUR HOUSEHOLD                             │  SCH, the whole card
│ Complimentary membership                   │
│ Everything a member has, with nothing to   │  D8 (grant_expires_at null)
│ pay and nothing to renew.                  │
└────────────────────────────────────────────┘
│ Everything a member has, until 17 Sep      │  D9 (grant_expires_at set)
│ 2027. After that the daily question keeps  │
│ going, free.                               │
```

Condition: `entitlement_source == "grant"` (`tier == "free"`, `access == "subscribed"`). `grant_expires_at` is read only when the source says `grant`, per the contract. No rows: nothing to manage, nothing to sell, nothing to restore. A dated grant says what follows the date, because there is no CTA or Manage row under it to imply that nothing does. A household holding both a receipt and a grant reports `receipt` and renders as 3.4.

Strings: H6, D8, D9 proposed (D9's second sentence derived from §3's approved body).

### 3.8 Unknown

Two sub-states, which are not the same state. In both, the headline is the approved "—" and the detail says why, because a dash on its own is not a word.

`household == nil` (the first read has not answered, or it failed):

```
┌────────────────────────────────────────────┐
│ YOUR HOUSEHOLD                             │  SCH, headline "—"
│ —                                          │
│ The app hasn't heard back from the server  │  D10
│ yet. It'll check again the next time you   │
│ open it.                                   │
├────────────────────────────────────────────┤
│ Become a member                            │  SAR (shipped behaviour; the sheet retries the read)
│ Membership is what fills in the rest of    │
│ the day.                                   │
├────────────────────────────────────────────┤
│ Restore a purchase                         │  SAR (re-reads /families/me)
│ If you've paid before and this phone       │
│ doesn't know it yet.                       │
└────────────────────────────────────────────┘
```

D10 is true in both halves of this state: while the first read is in flight and after it has failed, the app has not heard back, and it does check again — `refreshHousehold()` is the foreground re-check and `load()` runs on the card's `.task`. The pure function cannot tell a running read from a failed one, so the sentence was written not to need to.

`access` is a word this build cannot read, with `tier == "free"` (D9: entitled, never claimed):

```
┌────────────────────────────────────────────┐
│ YOUR HOUSEHOLD                             │  SCH, headline "—"
│ —                                          │
│ This version of the app can't read your    │  D11
│ membership yet. Nothing is held back; an   │
│ update will be able to show it.            │
├────────────────────────────────────────────┤
│ Become a member                            │  SAR (the offer follows isMember, §6)
│ Membership is what fills in the rest of    │
│ the day.                                   │
├────────────────────────────────────────────┤
│ Restore a purchase                         │  SAR
│ If you've paid before and this phone       │
│ doesn't know it yet.                       │
└────────────────────────────────────────────┘
```

The offer row stays, and the earlier draft that withheld it was wrong in its reasoning: "you do not sell to a household the server calls entitled" would also withhold it from the trial, which is entitled and offered. The rule that survives is the one `canBuy` and `dismissAfterRestore` already use — the offer keys on `!isMember` — so `settingsAction` does not change for this value at all. An unrecognised `access` with `tier == "subscribed"` renders as 3.4: `tier` is Apple's word, and the Manage row already keys on it. `access` absent (pre-107 server) and `.notReported` are not unknown; both fall back to `tier` exactly as today.

Strings: H7 shipped since 37a (§4 row); D10, D11 proposed.

### 3.9 Purchase in flight

`.purchasing` and `.confirming`, on a household that is not a member (here a trial):

```
┌────────────────────────────────────────────┐
│ YOUR HOUSEHOLD                             │  SCH, the server's last word, unchanged
│ Free trial                                 │
│ Until 17 Sep 2026. No card, nothing to     │
│ cancel.                                    │
├────────────────────────────────────────────┤
│ ◌ Finishing up                             │  phase 140's busy row, in the CTA slot
├────────────────────────────────────────────┤  ("Talking to the App Store" while .purchasing)
│ Restore a purchase                         │  SAR, isEnabled: false (inkMuted label)
│ If you've paid before and this phone       │
│ doesn't know it yet.                       │
└────────────────────────────────────────────┘
```

The header keeps the server's word; it never says "Finishing up" in the slot that names what the household is. Restore is disabled rather than removed, so two StoreKit operations cannot overlap and the card does not reflow mid-purchase. No wash: the spinner is the one "live" signal.

`.late` and `.awaitingApproval`: Apple has the money, or is waiting for a family organiser to approve it. The CTA slot carries the sentence, inside the card, as a plain row — the busy row without its spinner, `inkMuted` body — and "Become a member" is gone, because a parent who has just paid must not be invited, in the card's loudest colour, to do it again and meet Apple's "You're currently subscribed" dialog (the Sep 3 confusion phase 143 documented). Restore stays, enabled: it is the one control that can nudge the server.

```
┌────────────────────────────────────────────┐
│ YOUR HOUSEHOLD                             │  SCH, unchanged
│ Free trial                                 │
│ Until 17 Sep 2026. No card, nothing to     │
│ cancel.                                    │
├────────────────────────────────────────────┤
│ Your membership is being confirmed.        │  reported row (U1), no spinner
│ There's nothing else you need to do —      │  (U2 while .awaitingApproval)
│ it'll appear here shortly.                 │
├────────────────────────────────────────────┤
│ Restore a purchase                         │  SAR, enabled
│ If you've paid before and this phone       │
│ doesn't know it yet.                       │
└────────────────────────────────────────────┘
```

`.failed(message)`: the CTA and Restore rows return — this is the one terminal state with a retry behind the CTA (the sheet's, with Terms and Privacy beside it) — and the store's own sentence renders under the card:

```
└────────────────────────────────────────────┘
  The App Store's own sentence (SubscriptionStoreError.userMessage).
```

`.subscribed`: the household re-read flips the card to 3.4; no extra sentence, because the header now says so.

Strings: B1, B2, U1, U2 reproduced (§8a, 8b, 8d, 8e); U3 is the store's own sentence.

### 3.10 Restore in progress, found, nothing

Reachable only from 3.1, 3.2, 3.3, 3.8 and the `.late`/`.awaitingApproval` overlay of 3.9, since the row exists only there. In progress (here free):

```
┌────────────────────────────────────────────┐
│ YOUR HOUSEHOLD                             │  SCH
│ Free                                       │
│ The daily question is always free.         │
├────────────────────────────────────────────┤
│ Become a member                            │  SAR, enabled
│ Membership is what fills in the rest of    │
│ the day.                                   │
├────────────────────────────────────────────┤
│ Restore a purchase                      ◌  │  SAR isBusy → terracottaDeep spinner, disabled
│ If you've paid before and this phone       │
│ doesn't know it yet.                       │
└────────────────────────────────────────────┘
```

Found: the re-read household turns the card into 3.4 (both rows leave with it) and "Found it. Your membership is active." renders under the card — a restore that changed the header is news, and the sentence stays. It renders only when the restore was started from this card: `load()` clears `restoreConfirmation` on every card appearance (`SubscriptionModel.swift:321`), so a restore found from the paywall opened off Today never shows U4 here. Nothing: the card is unchanged and "Nothing has arrived yet. If you subscribed on another device, it can take a moment to appear." renders under it. Attached to another account (phase 143): the card is unchanged and that sentence renders under it.

Strings: U4 existing-approved §7 row 5; U5 shipped (`SubscriptionModel.restoreNothingYet`), with a proposed alternative U5′ in §6; U6 shipped (`SubscriptionModel.swift:896`, phase 143), not yet in the copy file.

### Presence rules, in wire terms

`isSubscribed` is `tier == "subscribed"`; `isGranted` is `entitlement_source == "grant"`; `isMember` is `isSubscribed || isGranted` (`FamilySummary`, all unchanged). `inFlight` is `purchase ∈ {.purchasing, .confirming}`; `reported` is `purchase ∈ {.late, .awaitingApproval}`.

| Element | Present when |
|---|---|
| Header | Always. Headline: nil household → "—"; `access` absent or `.notReported` → `isSubscribed` ? plan headline : "Free"; `.subscribed` → `isGranted` ? "Complimentary membership" : (`isSubscribed` ? plan headline : "Membership"); `.trial` → "Free trial"; `.free` → "Free"; `.unrecognised` → `isSubscribed` ? plan headline : "—". Plan headline: `annual` → "Annual membership", `monthly` → "Monthly membership", else "Membership". |
| Header detail | Nil household → D10. `.trial` → D1 (D1b without a date). `.free`, or `access` absent with `tier` free → D2. `isSubscribed` and `is_payer != false` → `billing_retry` ? D7 : (`expires_at` ? (D3 / D4 / D5 + D5p by `auto_renew`) : nil). `isSubscribed` and `is_payer == false` → (`expires_at` and not `billing_retry` ? D3 / D4 / D5 : nothing) then D6; never D7. `isGranted` → `grant_expires_at` ? D9 : D8. `.unrecognised` with `tier` free → D11. "Membership" with `tier` free (pre-121) → nil. |
| Busy row | `!isSubscribed` and `inFlight` (today's `settingsAction` ordering, unchanged): B1 / B2 with the spinner. |
| Reported row | `!isSubscribed` and `reported`: U1 / U2, plain, no spinner. New. |
| Become a member | `household == nil`, or `!isMember` and `purchase ∈ {.idle, .failed, .subscribed}`. Detail R2t when `access == .trial`, else R2. |
| Manage subscription | `isSubscribed` and `is_payer != false`. Unchanged. Detail R4′; R4r while `billing_retry`. |
| Restore a purchase | `household == nil` or `!isMember`; member states hide it whatever `purchase` says. Disabled while `inFlight` or `isRestoring`; enabled while `reported`. Last row. |
| Line under the card | `restoreConfirmation ?? notice ?? purchaseLine(purchase)`. `purchaseLine` now carries only `.failed`'s message; U1 and U2 moved into the card. |

## 4. Strings, all in one table

Status: **approved** = owner-authored, in `docs/design/free-tier-copy.md` or chosen by the owner (cited); **reproduced** = shipped before the copy file described the surface and recorded there as reproduced rather than authored (cited); **shipped** = in the tree, not in the copy file, proposed to keep verbatim unless marked otherwise (cited); **proposed** = new, for the owner to approve or reword; goes to Proposed additions §9, never straight into a view. `{date}` is a literal placeholder in the constant and the only place a rendered digit can appear; no template carries one. Check column: the banned list (`Unlock`, `Upgrade`, `Premium`, `Pro` whole-word, `Free trial ending`, `Don't lose`, `You've missed`, `Limited time`, `Only X left` as the only+left shape, `Your archive will be`, `Members only`, `Locked` as a label) and rules 1 through 6. No proposed string carries an em dash; the two existing strings that do are the footnote (the owner's, §7 row 3) and the late line (phase 37b's, reproduced, §8d).

| id | Where | String | Status | Check |
|---|---|---|---|---|
| S1 | Section header | Membership | shipped, `SubscriptionSection.swift:33` | clear |
| S2 | Header eyebrow, every state | Your household | approved, §7 row 1 (Aug 26) | clear |
| H1 | Headline, trial | Free trial | proposed; replaces "Everything open" (§4, chosen Aug 22, retired here) | not "Free trial ending"; the composed label never puts "ending" beside it; rule 1: a state, not a clock |
| H2 | Headline, free (never or lapsed) | Free | reproduced, §4 row ("shipped since 37a, reproduced not authored") | clear |
| H3 | Headline, subscribed, `plan == "annual"` | Annual membership | proposed; §6 floated "Subscribed — annual" | rule 2 vocabulary (membership) |
| H4 | Headline, subscribed, `plan == "monthly"` | Monthly membership | proposed | rule 2 |
| H5 | Headline, subscribed with `plan` null/unrecognised; also `access` subscribed with no receipt and no grant | Membership | proposed | claims no cadence and no Apple word the server did not say |
| H6 | Headline, granted | Complimentary membership | proposed (phase 141 left this state wordless) | rule 2; not "Subscribed" for a household with no Apple subscription |
| H7 | Headline, unknown | — | reproduced, §4 row ("shipped since 37a") | clear |
| D1 | Detail, trial with date | Until {date}. No card, nothing to cancel. | first clause proposed; second sentence §3's approved body, first sentence verbatim | rule 1: a date the server sent, no count; no digit in the template; two short sentences |
| D1b | Detail, trial, date absent (defensive) | No card, nothing to cancel. | §3's approved body, first sentence verbatim | as D1 |
| D2 | Detail, free | The daily question is always free. | approved, §2 title (`MembershipCopy.title`) | rule 6 |
| D3 | Detail, subscribed, `auto_renew == true` | Renews {date} | proposed (Apple's word) | plain, quiet; exact, since `auto_renew` is Apple's own status (§7) |
| D4 | Detail, subscribed, `auto_renew == false` | Expires {date} | proposed (Apple's word and the owner's; `design-system.md:750`: "Expiry is stated plainly and quietly") | not on the trial; only on a subscription the parent has turned off |
| D5 | Detail, subscribed, `auto_renew` null or absent | Paid through {date} | proposed; the neutral word, true whichever way auto-renew is set | clear |
| D5p | Appended to D5 when the Manage row is present | Whether it renews is set in the App Store. | proposed | answers the question D5 leaves open, and points at the row beneath |
| D6 | Detail, subscribed, `is_payer == false`; appended | Managed by the other parent. | proposed; §6 proposed it Aug 22 as a value row, never approved | "the other parent" is the Guardians row's own phrase |
| D7 | Detail, subscribed, `billing_retry == true`, `is_payer != false`; replaces the date line | The App Store couldn't take the last payment and will try again. Membership carries on in the meantime. | proposed; one constant, two sentences | rule 1: a fact then the reassurance; "couldn't take" rather than "failed" or "problem"; no "before"; "carries on", not "stays open" — "Everything … open" is the phrase the owner opened the brief with |
| D8 | Detail, granted, perpetual | Everything a member has, with nothing to pay and nothing to renew. | proposed | rule 2; no "only" |
| D9 | Detail, granted with expiry | Everything a member has, until {date}. After that the daily question keeps going, free. | proposed; second sentence derived from §3's body | rule 1: a date, no count; rule 6: says what follows, positively |
| D10 | Detail, no household yet | The app hasn't heard back from the server yet. It'll check again the next time you open it. | proposed | true while loading and after a failed read; says what happened and what happens next; no apology (`design-system.md` copy rules) |
| D11 | Detail, `access` unrecognised, `tier` free | This version of the app can't read your membership yet. Nothing is held back; an update will be able to show it. | proposed | D9's direction said out loud; no "open" |
| R1 | CTA label, all non-member states | Become a member | approved, §2 primary action (`MembershipCopy.primaryAction`); rule 2's verb | clear |
| R2 | CTA detail, free, lapsed, no household, unrecognised | Membership is what fills in the rest of the day. | approved, §2 subtitle (`MembershipCopy.subtitle`) | rule 3: more of the day, never the archive |
| R2t | CTA detail, trial | Keeps the missions going after the trial. You're charged when you join, not when it ends. | proposed | rule 3; the charge stated as a fact, not a lever; no digit, no date (the header two lines up carries it); not "Free trial ending" |
| R3 | Manage label | Manage subscription | shipped, `SubscriptionSection.swift:63` | Apple's noun for Apple's sheet |
| R4 | Manage detail, today | Change the plan or cancel, in the App Store. | shipped, `:64`; proposed to be replaced by R4′ | clear |
| R4′ | Manage detail, every subscribed state except retry | Change the plan or cancel in the App Store, from the Apple Account that pays for it. | proposed; changes a shipped string | says where the sheet works, for the null-payer parent whose sheet is empty; Apple's nouns |
| R4r | Manage detail, `billing_retry == true` | Change the plan or cancel in the App Store, from the Apple Account that pays for it. The payment method is in that account's settings. | proposed | names the second place rather than promising the sheet reaches it; no "update", no "fix" |
| R5 | Restore label | Restore a purchase | shipped; §7 kept the title for Review 3.1.2(c) | clear |
| R6 | Restore detail | If you've paid before and this phone doesn't know it yet. | approved, §7 row 4 | clear |
| B1 | Busy row, `.purchasing` | Talking to the App Store | reproduced, §8a (`PurchaseCopy`) | clear |
| B2 | Busy row, `.confirming` | Finishing up | reproduced, §8b | clear |
| U1 | Reported row in the card, `.late` | Your membership is being confirmed. There's nothing else you need to do — it'll appear here shortly. | reproduced, §8d (phase 37b's sentence) | clear |
| U2 | Reported row in the card, `.awaitingApproval` | This purchase needs approval. Once it's approved, the app will notice on its own. | reproduced, §8e | clear |
| U3 | Under the card, `.failed` | the store's own `SubscriptionStoreError.userMessage` | shipped | Apple's |
| U4 | Under the card, restore found | Found it. Your membership is active. | approved, §7 row 5 (Aug 26) | clear |
| U5 | Under the card, restore found nothing | Nothing has arrived yet. If you subscribed on another device, it can take a moment to appear. | shipped, `SubscriptionModel.restoreNothingYet` (37b) | clear |
| U5′ | Under the card, restore found nothing (owner option) | Nothing has arrived yet. If you've never subscribed, there's nothing to restore; if you subscribed on another device, it can take a moment to appear. | proposed; changes a shipped string, model-side | no scold; tells the curious parent and the Sep 2 parent apart in one sentence |
| U6 | Under the card, receipt on another account | This App Store subscription is attached to a different Pocket Chronicle account. Sign in with that account, or subscribe here with a different Apple Account. | shipped, `SubscriptionModel.swift:896` (phase 143, Sep 3), in no section of the copy file; this phase records it in §9 because this card is the surface that renders it | clear |

Removed from this card (constants stay for the sheet): "Everything open" (`Status.everythingOpen`, retired outright), "Subscribed" (`Status.subscribed`; no state renders it under the recommended headlines, so it retires with `everythingOpen` — it survives only if open decision 2 goes the other way), "See what membership includes" (§7 row 2, retired), "One price covers everyone in the house — every parent, every child." (stays as the sheet's footnote), "Yours either way" and its three lines (`freeLabel`, `stayFree`, still rendered by `PaywallSheet`).

VoiceOver, composed by the components, no new strings: the header reads eyebrow, headline, detail joined by ". " ("Your household. Free trial. Until 17 Sep 2026. No card, nothing to cancel."); each action row reads "label. detail" with the button trait; the busy row and the reported row are one combined element each; the line under the card is its own element.

## 5. Days left and "expires when"

**The collision.** The owner asked for "how many days are left". Copy rule 1 says "no countdown on the trial"; `free-tier-copy.md` Proposed additions §4 says "No date, no day count, no 'ends on'"; `SettingsMembershipTests.noStatusAnswerCounts` bans a digit in any status string; `theRowDoesNoArithmetic` bans the tokens `trialEndsAt` and `trial_ends_at` in the two surface files. The contract says `trial_ends_at` is "for copy only", so rendering it is permitted; counting is what is banned.

**Recommendation: (a), the date, never a count.** All four designs and all three judges landed here, and the reasons are not close. A date does not tick: "Until 17 Sep 2026" is the same sentence on day 1 and day 13, which is the whole difference between a fact and a countdown. It is the server's own instant rendered by the formatter Settings already uses for a dated commitment, so the surface does no arithmetic and the device never decides what day it is (`ios/CLAUDE.md` rule 1, D5, D9). It is what the platform does: Apple shows "Expires Sep 17", never "13 days left". And a parent who reads "until 17 Sep" on the 10th knows how long that is without the app counting for them. Option (b), "13 days left", is a countdown by the copy rule's own definition; computed on the device it is off by one at the day boundary for a parent in a different zone from the child, and computed on the server it is a new field whose only job is to render the thing rule 1 bans. Option (c) inherits everything wrong with (b).

**Which day the date names.** `trial_ends_at` is an instant (`now + 14 days` at INSERT, `models/family.py:37-43`), and `DayHeaderText.dayAndMonth` renders it through the device's calendar and zone. "Until {date}" therefore names the calendar day the server's instant falls on in the reader's zone; the gate is still the server's, the missions can stop partway through that day, and the next read corrects the card (`refreshHousehold()` on foreground, `load()` on appearance). That half-day imprecision is formatting, not arithmetic — it does not breach D5 or D9 — and it is recorded as accepted rather than hidden. "Through {date}" would be exact only if the API lane wrote the instant as end-of-day in `family_timezone`, which is not requested here.

**What the owner must decide or amend for (a):**

1. Amend copy rule 1 with one clause: "The date a trial ends may be stated once, as the server sent it, as the calendar day that instant falls on for the reader. A number of days may not."
2. Strike "No date, no day count, no 'ends on'" in Proposed additions §4 for the date only, as a dated reversal; "Everything open" (his Aug 22 pick) is retired from Settings and the record says so.
3. `decisions.md` D9 row: "`trial_ends_at` is on the wire and is read by nothing: no countdown, no arithmetic" becomes "read for display only — the calendar day the server's instant falls on in the reader's zone; no countdown, no arithmetic; the gate is the server's and the next read corrects the card". The `MembershipCopy.Status` doc comment ("No countdown and no date") changes the same way.
4. Test `theRowDoesNoArithmetic`: drop `trialEndsAt` and `trial_ends_at` from the banned tokens; keep `timeIntervalSince`, `Date()`, `Date.now`, `dateComponents`, `Calendar` banned (`Date.formatted` trips none of them); add a positive assertion that the trial detail contains `DayHeaderText.dayAndMonth(serverDate)` verbatim. Its doc comment gains the sentence that fixture and preview dates in the two scanned files are built with `ISO8601Formatters.parse("2026-09-17T00:00:00Z")!` (`APIClient.swift:624`), which contains none of the kept tokens, so the constraint travels with the test. The surface may read and format a server date and may never compute from one.
5. Test `noStatusAnswerCounts`: keep, widened to every authored constant (headlines and detail templates; none carries a digit), and asserting that the dated templates (D1, D3, D4, D5, D9) carry exactly one `{date}` and the rest none; doc comment updated to "a rendered date is permitted, a day count is not".
6. A new test that a `trial_ends_at` in the past beside `access == "free"` renders 3.2 — "Free", D2 — and never "Free trial" over a past date. The header keys on `access`, so this is a pin rather than logic, and it is the pin that stops a later phase keying it on the date.

**If the owner overrules and wants (b):** everything above, plus an API-lane field `trial_days_left: int | null`, server-computed as whole days remaining until `trial_ends_at` (null when there is no live trial); rule 1 rewritten to permit a count on this one surface; `noStatusAnswerCounts` rewritten to allow a digit that came from that field; and the acceptance that "9 days left" would sit one tap from the paywall's approved "with no limit and no countdown". The one rule-consistent shape for a number already exists in `design-system.md:295`: a quiet `chipPlain` `inkMuted` count shown **only within three days** of expiry ("2 days left", "1 day left", "Last day"), from server dates, never before that and never on day one. If a number is wanted, it should be that shape and nothing louder. I would still advise against.

**"Expires" for a subscription.** With today's API nothing dated can be shown; the header reads "Annual membership" alone and Apple's Manage sheet carries the date one tap away. With the API half: "Renews {date}" / "Expires {date}" when the ledger's last payload carried Apple's `autoRenewStatus`, and "Paid through {date}. Whether it renews is set in the App Store." when it did not (§7 says when that is). "Expires" is used only for a subscription whose renewal the parent has turned off, which is where Apple uses it; it never appears on the trial.

## 6. Restore

**Where:** the last row of the card, under "Become a member" or the reported row, with its label and detail unchanged (`SettingsActionRow`, `terracottaDeep`).

**When:** `household == nil`, or `household.isMember == false`: trial, free (never or lapsed), and an unrecognised `access` on a free tier. Hidden for every member state — subscribed (payer, unknown payer, explicit non-payer, billing retry) and granted — whatever `purchase` says. Disabled, not removed, while a purchase is `.purchasing` or `.confirming`; enabled while `.late` or `.awaitingApproval`; busy and disabled while `isRestoring`. Outcomes render on the existing line under the card.

**Why this is right:**

- App Review 3.1.1/3.1.2 wants a restore mechanism and Terms/Privacy on the paywall; `PaywallSheet.swift:500-566` carries all three, and that sheet is reachable from every non-member state through this card's CTA. The Settings row was never the compliance control, so hiding it from members costs nothing with Review. Keeping the label verbatim where it does show is what §7 preserved for recognisability.
- The Sep 2 incident is the row's entire purpose: this phone held a sandbox receipt the server could not see, and the app read `free` or `trial`. Every version of that story reads as a non-member state, because the server not knowing about a purchase is exactly what makes `access` not `subscribed`. The row is present in every state that incident can produce, and it is on this card rather than only in the paywall because reaching it through "Become a member" while holding a paid receipt is the insult the incident was about.
- For a household the server already calls a member, `restore()` can only re-read the same answer; since phase 140 a submission "may only ever promote", and there is nothing to promote. A control whose only outcome confirms the line above it is furniture. That is the contradiction phase 141 removed for grants: a restore that could only confirm the header. A restore that *changes* the header — a free card that becomes "Annual membership" — keeps its "Found it" sentence, because that is news and not an echo; an engineer must not read this bullet as a reason to suppress U4 after a found restore.
- Below the CTA rather than above it: a parent who has never paid must not meet "Restore" before "Become a member". Both are terracotta because both are things you do; the order carries the weight.
- Disabled during a purchase so two StoreKit operations cannot overlap and the card does not reflow the moment the sheet dismisses itself. Enabled in `.late` and `.awaitingApproval` because those are the states where the server has not yet caught up and a restore is the one thing on the card that asks it to.
- The row's own words are for the Sep 2 parent, and a curious never-paid parent who taps it reads U5 — "Nothing has arrived yet. If you subscribed on another device…" — which implies something is on its way. The card cannot tell the two apart. U5′ (§4) is the one-sentence fix, proposed for the owner; it changes a shipped model string, not a view, and is listed in §11 either way.

Implementation: a named pure function, `MembershipPresentation.settingsRestore(for:purchase:) -> RestoreRow` with cases `.offered`, `.waiting` (purchase in flight), `.hidden`. Precedence is stated, not implied: `isMember` → `.hidden` regardless of `purchase`; then nil or non-member → `inFlight` ? `.waiting` : `.offered`. Tested across nil, trial, free, lapsed, subscribed with each payer value, granted, unrecognised access, `.purchasing`, `.confirming`, `.late`, `.awaitingApproval`, and the cells where they meet: granted + `.confirming` and granted + `.purchasing` expect `.hidden` (the busy row still shows above, per `aGrantDoesNotHideFinishingUp`); trial + `.late` expects `.offered`.

## 7. API needs

Two additive, optional fields, both describing the current subscription under the invariant `plan` already has: never beside `access: "free"`, null for a non-member. They go on **both** shapes — `FamilyOut` and `EntitlementOut` — because that is the tree's own rule for `plan` and `billing_retry` ("one function, `services.membership.membership_signals`, two shapes", `schemas/family.py:196`; `api-contract.md:2174`), and the entitlement handler already holds the `signals` object they come from (`routers/families.py:262`). A client that ignores them behaves exactly as before; a client that reads them from an old server sees them absent and renders the header without a date line.

**`expires_at`: `datetime | null`.** Apple's `expiresDate` from the same `app_store_transactions` row `membership_signals` already reads for `plan` and `billing_retry` (`models/app_store.py:82`, `expires_date`, nullable). The console already serialises this exact column under this exact name (`services/admin_metrics.py:1064` and `:1218`). One rule, stated once: null when `tier != "subscribed"`; when there is no ledger row (the hand-written household, `runbook-deploy.md` §7a); when Apple sent no `expiresDate`; when `expires_date <= now`; **or when `billing_retry` is true**. The last two are why no client ever renders "Renews {past date}": a past date is a stale ledger or webhook lag, and the date on a row in retry is the date the renewal failed on, which the client displaces with D7 anyway. The comparison is a plain instant comparison against `dt.datetime.now(tz=dt.UTC)` — there is no `now_utc()` helper in this tree — behind an injectable `now: dt.datetime | None = None` keyword on `membership_signals`, mirroring `access_for` (`services/guardians.py:117-118`), threaded from `_family_out` and `read_entitlement` so a test can shift the clock without sleeping. For copy only; the client formats it and never compares it to a clock.

**`auto_renew`: `bool | null`, and it is exact rather than inferred.** Every subscription notification Apple sends carries `signedRenewalInfo`, and this service already verifies and decodes it into the stored payload: `raw_payload["data"]["renewalInfo"]["autoRenewStatus"]` is on every ledger row a notification wrote (`services/app_store.py:433`, pinned by `test_app_store.py:234`). The field is that value — `1` → `true`, `0` → `false` — read as a JSONB path expression in the same `select` `membership_signals` already makes, so the blob is never loaded into Python and the query stays one indexed lookup. Null when the row's last payload carries no `renewalInfo` (the `SUBMITTED` marker a phase-140 submission writes holds a transaction JWS, `app_store_events.py:720`, and a notification type that omits it), and always null when `expires_at` is null. No migration (the latest is `0026_console_indexes.py`; nothing is added), no new column, no constants for the `AUTO_RENEW_*` subtypes, and none of the three faults of deriving it from `latest_notification_type`: it does not over-report `true` after a missed `AUTO_RENEW_DISABLED` (the next notification of any type carries the current status), it does not flap to null on a `PRICE_INCREASE` or `DID_CHANGE_RENEWAL_PREF`, and it is not a claim Apple's last word contradicts. The contract row says so in the same words `billing_retry`'s row uses for its opposite: this field is the last thing Apple said, and every notification refreshes it.

**Fallback rendering against a server that does not send them:** `expires_at` absent or null → no date line; the subscribed header is headline only (3.4, second mockup). `auto_renew` absent or null with a date → "Paid through {date}", plus D5p where the Manage row is. Everything else on the card is identical.

**Already on the wire, decoded by nothing, iOS half only:** `trial_ends_at` (decoded on `TodayResponse` today, not on `FamilySummary`) and `grant_expires_at`. No server change.

**Not requested:** `trial_days_left` (section 5); an end-of-day `trial_ends_at` in `family_timezone` (section 5); `renewalInfo.gracePeriodExpiresDate` (the retry state renders no date by design).

**Lane split.** API half: `services/membership.py`, `schemas/family.py`, `routers/families.py`, `docs/api-contract.md`, `tests/test_membership_wire.py`. iOS half: everything in section 8. Either can ship first: the API half is invisible until the iOS half decodes it, and the iOS half without the API half renders the bare subscribed header. The API half is the smaller diff and turns the owner's "expires when" on the day the iOS half lands, so it should go first. The two fields ship together: `expires_at` alone would make "Paid through" the default render for every subscriber rather than the rare fallback, which is the ambiguity D5p exists to soften and not to be (open decision 3).

## 8. What changes in code

The phase number comes from `docs/roadmap-status.md`, read from the file. The `/phase` orchestrator cuts one worktree per lane.

### iOS lane

- **`Networking/FamiliesAPI.swift`** — `FamilySummary` gains `trialEndsAt: Date?`, `grantExpiresAt: Date?`, `expiresAt: Date?`, `autoRenew: Bool?`. All optional, for the reason `billingRetry`'s doc comment gives: a missing key must never fail the household decode (pinned by `aPre113ServerStillDecodes`). Declared as `var … = nil`, and that is not a style choice: a `let` with an initial value is excluded from both the synthesized memberwise init and synthesized `Decodable` (the compiler warns "immutable property will not be decoded"), so `let expiresAt: Date? = nil` would decode nothing. `let` without a default is the only `let` form, and it means touching all eight memberwise-init call sites (`GuardiansSection.swift:234`, `SubscriptionSection.swift:217`, `PurchaseReportingTests:154`, `SubscriptionScreenshotTests:483`, `SubscriptionTests:185, 213, 1667, 2222`). `var … = nil` keeps the eight unchanged and decodes; `Equatable` and `Decodable` synthesis are unaffected.
- **`Subscription/MembershipPresentation.swift`** — `settingsStatus(for:) -> String` becomes `settingsHeader(for:) -> MembershipHeader` (`headline: String`, `detail: String?`), a pure function of `FamilySummary?` whose only date reads are `DayHeaderText.dayAndMonth` calls and whose composition only joins registered constants with a space. `settingsAction(for:purchase:)`, written out case by case so two engineers build one `.offer` set:
  - `household == nil` → the `purchase` switch below with no household (so `.offer` when idle; shipped).
  - `household.isSubscribed` → `mayManageSubscription ? .manage : .hidden` (unchanged; the server wins over any local purchase state).
  - otherwise by `purchase`: `.purchasing` → `.finishing(B1)`; `.confirming` → `.finishing(B2)`; `.late` → `.reported(U1)`; `.awaitingApproval` → `.reported(U2)`; `.idle`, `.failed`, `.subscribed` → `isGranted ? .hidden : .offer`.
  - `access` plays no part: `.trial`, `.free`, `.unrecognised`, `.notReported` and absent all reach the same branch, so the offer follows `isMember` exactly as `canBuy` does (`SubscriptionModel.swift:281`). The pre-121 cell — `access == .subscribed`, `tier` free, no `entitlement_source` — answers `.offer`, which is today's answer, under an H5 "Membership" headline; it is the phase-141 contradiction on a server that is not serving, and it is named rather than fixed.
  - **The one change to `settingsAction`** is `.late` / `.awaitingApproval` → `.reported(String)` where today they return `.offer` — and it applies to a granted household too, so `aGrantDoesNotHideFinishingUp`'s third assertion moves from `.hidden` to `.reported(PurchaseCopy.late)`, in the same spirit as its first two.
  - New: `offerDetail(for:) -> String` (R2t when `access == .trial`, else R2), so `.offer` keeps its shape and the four tests comparing `== .offer` stay as they are. New: `settingsRestore(for:purchase:) -> RestoreRow` (section 6). `purchaseLine(for:)` now returns only `.failed`'s message: U1 and U2 are the row's, and a sentence rendered in the card must not also render under it. `dismissAfterPurchase`, `dismissAfterRestore`, `boardNeedsReload` untouched.
- **`Subscription/MembershipCopy.swift`** — every headline and detail template is a `String` constant. The five dated ones (D1, D3, D4, D5, D9) carry a literal `{date}` placeholder — the tree already renders `{them}` tokens through `PromptTokens.render` — and one `MembershipCopy.render(_ template: String, date: String) -> String` substitutes it; a function cannot sit in `allUserVisibleStrings: [String]` (`:298`) or be scanned, and a sample date carries digits. Every constant, D7's two sentences as one constant, D5p on its own, R2t, R4′, R4r, D10 and D11 included, is listed in `allUserVisibleStrings`, which is what `MembershipTests.noBannedWordShipsInUserVisibleCopy` (`MembershipTests.swift:1112`) iterates — not `noBannedWordInAnySurfaceSource`, whose file list is views and the model, not this file. `Status.everythingOpen` and `Status.subscribed` retire (the latter survives only if open decision 2 picks it); `Status.free` and `Status.unknown` become the headline constants they already are. Doc comment "No countdown and no date" updated per section 5. `freeLabel`, `stayFree`, `footnote`, `title`, `subtitle` unchanged (the sheet renders them).
- **`Subscription/SubscriptionSection.swift`** — `SettingsValueRow("Your household", …)` becomes `SettingsCardHeader(eyebrow: "Your household", headline:, detail:)`, the component's first call site (it is defined in `Settings/SettingsRow.swift:91-148` and used by nothing today). `reassurance` and `reassuranceGap` removed. The `.offer` row's label and detail become `MembershipCopy.primaryAction` / `offerDetail(for:)`. The `.reported` row is the busy row's `HStack` without the `ProgressView`. The Manage row's detail is `R4r` when `isInBillingRetry`, else `R4′`. The Restore row is wrapped in `settingsRestore`'s answer and passes `isEnabled: false` for `.waiting`. Previews: the three "Restore" previews move to a free household (the state restore exists for); new previews for lapsed, granted (both), billing retry, unrecognised access, `.late`, and a subscribed household with each `auto_renew` value. **Every preview date is `ISO8601Formatters.parse("2026-09-17T00:00:00Z")!`** — the `previewing(…)` helper lives in this file, which `theRowDoesNoArithmetic` scans previews included, and every other way to build a `Date` (`Date()`, `Date.now`, `Calendar.current.date(…)`, `Date(timeIntervalSince1970:)`) contains a kept banned token.
- **Tests that change, and why:**
  - `SettingsMembershipTests.trialNoLongerReadsFree`, `subscribedReadsSubscribed`, `freeReadsFree`, `noHouseholdClaimsNothing`, `absentAccessFallsBackToTier`, `unrecognisedAccessClaimsNothingAndStillEntitles`, `futureFieldsDecodeAndChangeNothing`, `absentNewerFieldsStillRender`: assert `settingsHeader(for:).headline` instead of a string; the trial case asserts "Free trial" and gains a detail assertion carrying the formatted date; the nil and unrecognised cases gain D10 / D11 detail assertions.
  - `noStatusAnswerCounts`: rescoped to every authored constant, with the `{date}` count assertion; doc comment updated (section 5).
  - `theRowDoesNoArithmetic`: two tokens dropped, five kept, one positive assertion added, the fixture-date sentence in its doc comment (section 5).
  - `theReassuranceIsTheApprovedBlock`: survives as written (it pins `MembershipCopy.freeLabel`/`stayFree`, which the sheet still renders); its comment now says it pins the sheet, not the card.
  - `noStatusAnswerIsBanned`: iterates the new constants.
  - `MembershipTests.noBannedWordInAnySurfaceSource`: `Subscription/MembershipPresentation.swift` added to its file list, since that is where details are composed.
  - `MembershipWireTests`: `unknownPayerKeepsManage`, `explicitPayerGetsManage`, `explicitNonPayerIsOfferedNothing`, `trialIsOfferedMembershipNotManage`, `noHouseholdIsOfferedMembership` pass unchanged. `aLapsedHouseholdCarriesNoPlan` (`:522`) and `graceMovesNoGate` (`:537`) **cannot** pass unchanged — both call `settingsStatus` — and change to `settingsHeader(for:).headline == "Free"` and `== "Membership"` respectively (that fixture carries no `plan`, so the headline is H5, not a plan noun). New: the `settingsRestore` matrix; the `settingsAction` switch across every `access` value including `.notReported` and `.unrecognised` (all `.offer` when not a member); decode of the four new optional fields, present and absent; the past-`trial_ends_at`-beside-`free` pin.
  - `PurchaseReportingTests.purchaseLineTable`: `.late` and `.awaitingApproval` now expect `nil`; the two sentences are asserted on `settingsAction` instead.
  - `SubscriptionTests.theCardSaysNothingToAGrantedHousehold`: its status assertion (`== Status.subscribed`, `:2236`) becomes `.headline == "Complimentary membership"`; the `.hidden` assertion survives. `aGrantDoesNotHideFinishingUp`: third assertion moves to `.reported(PurchaseCopy.late)`. `aTrialIsStillOffered`, `aGrantedRestoreIsSilent` pass unchanged.
  - `SubscriptionScreenshotTests`: no golden diff (its own header says the PNGs "must be looked at"); the seven fixtures re-render and gain granted, retry, lapsed and `.late`. Per `CLAUDE.md`, the phase shows the PNGs at default, XXL and AX3, not a summary of having looked.
- **Docs:** `docs/design/free-tier-copy.md` Proposed additions §9 (the table in section 4 including U6, plus the dated reversals of §4's "Everything open" and "No date, no day count", and of §5's reassurance-on-the-card); `docs/design-system.md` § SettingsRow family (`SettingsCardHeader`'s entry gains this card as a second described use and one clarifying clause — "a sentence or two, never a paragraph" — which is what the slot already is and what every detail here obeys); `docs/decisions.md` D9 row, one line; `docs/decisions-log.md`, one line each for the conditional Restore row, the offer following `isMember`, the reported row displacing the offer in `.late`/`.awaitingApproval`, and the accepted half-day imprecision of "Until {date}".

### API lane

- **`services/membership.py`** — `MembershipSignals` gains `expires_at: dt.datetime | None` and `auto_renew: bool | None`; `NO_SIGNALS` carries both as `None`. `membership_signals` gains `now: dt.datetime | None = None` (defaulting to `dt.datetime.now(tz=dt.UTC)`, the pattern `access_for` uses). The `select` adds `AppStoreTransaction.expires_date` and the JSONB path to `raw_payload["data"]["renewalInfo"]["autoRenewStatus"]`, as scalars, never the blob. The null rule for `expires_at` (five conditions, section 7) and the `auto_renew` read live here, beside `billing_retry`'s, with the doc comment saying why one is exact and the other under-reports.
- **`schemas/family.py`** — `FamilyOut` and `EntitlementOut` both gain both fields, optional, default `None`, with doc comments in the style the phase-113 fields carry and the same "one function, two shapes" sentence `plan` already has.
- **`routers/families.py`** — **one `FamilyOut(...)` construction, not two**: `_family_out` at `:147`, which `GET /families/me` (`:92`) and `POST /me/transactions` (`:227`) both return through. `EntitlementOut(...)` at `:263` is the entitlement route's, and it passes the same two `signals` values. Both handlers thread `now` only if they already hold one; otherwise the default clock is the one they use today.
- **`constants.py`** — nothing. The `AUTO_RENEW_*` subtypes are not read.
- **`docs/api-contract.md`** — two rows added to the phase-113 table under `GET /families/me` (`:735-740`), with the null semantics above and the same "describes a current subscription" sentence; the entitlement route's paragraph (`:2174`) extended from two values to four; `auto_renew`'s row records that it is Apple's own `autoRenewStatus` from the last payload and is refreshed by every notification.
- **`tests/test_membership_wire.py`** — an annual subscription posted with a future `expires_date` reports it as `expires_at`; a lapsed household reports null though the row holds a date; a past `expires_date` on a subscribed household reports null, with `now` injected rather than slept for; **grace reports null even with a future `expires_date` on the row** (the fixture's `SUBSCRIBED` post sets one — the stub's default is none, `app_store_stub.py:248`, so the existing grace test proves nothing about this field); `auto_renew` true when the last payload's `renewalInfo.autoRenewStatus` is `1`, false when `0`, null for a `SUBMITTED` row and for a payload without `renewalInfo`, and null whenever `expires_at` is null; a free household never carries either; `GET /families/{id}/entitlement` reports the same two values; `test_the_new_fields_are_additive_and_change_nothing_that_was_there`'s `set(body)` grows by exactly two keys, which is the contract change that assertion exists to make deliberate.

## 9. Edge cases

- **Dynamic Type XXL and AX3.** The header is a `VStack` whose headline and detail carry `fixedSize(horizontal: false, vertical: true)`, so nothing truncates. The longest header detail (D7, D11, D9, about a hundred characters) wraps to two lines at the default size and five or six at AX3; no detail is a paragraph. The longest text on the card is an action-row detail (R4r), which already wraps. There is no trailing value anywhere on the card, which removes today's failure where "Everything open" fought "Your household" for one line. The counter slot is unused. The busy row's spinner and two-word label stay on one line; the reported row wraps like a detail.
- **VoiceOver grouping.** Header: one element, eyebrow. headline. detail, no heading trait (so the rotor still lists only the section headers). Each row: one button reading "label. detail". Busy row and reported row: one combined element each. Under-card line: one text element. Reading order is the visual order. The date is spoken as the formatter renders it; if the abbreviated month reads badly, the fix is a one-parameter addition to `SettingsCardHeader` (an optional spoken detail), not a call-site trick, because the component builds its label from the visible strings.
- **`is_payer` null vs false.** Null, the common two-guardian case, renders exactly as `true`: Manage present, D7 and R4r in retry. The words on the Manage row are what carry the difference for the parent whose Apple Account did not buy it (R4′); the server cannot, and this card does not pretend it can. Only an explicit `false` hides Manage and appends D6; a non-payer never sees D7. `mayManageSubscription` (`!= false`) is reused unchanged. A one-guardian household with `is_payer == false` (a payer who deleted their account, phase 143's case) reads "the other parent" for a parent who is gone; rare, and "Managed from another account." is the neutral alternative if the owner prefers it.
- **`plan` null while subscribed.** Headline "Membership", Manage present, date line if `expires_at` arrived. Never a guess at cadence and never a claim about billing (the hand-written household has no App Store transaction at all, so both new fields are null for it too). An unrecognised `plan` ("quarterly") is a lookup miss and renders as null.
- **Old server.** Pre-113: no `plan`/`billing_retry`/`is_payer` → "Membership", no retry sentence, Manage shown with R4′. Pre-107 (no `access`): `tier` fallback, exactly as today. Pre-121 (no `entitlement_source`): a granted household reads `access` subscribed with `tier` free → "Membership", the offer row (today's answer), Restore shown — the phase-141 contradiction, on a server that is not serving; defensive only. New fields absent: no date line; nothing else moves.
- **Granted with expiry.** `grant_expires_at` non-null → D9; null → D8 (perpetual; no date invented). Read only when `entitlement_source == "grant"`. When the grant ends the server flips `access` to `free` with `lapsed_at` null (a grant ending is not a lapse), and the card becomes 3.2 with the offer and Restore rows back, with no client logic.
- **Unrecognised `access`.** `tier` free → "—" over D11, the offer row, Restore; `Access.isEntitled` is untouched and the board stays open (D9), and the offer is there because `isMember` is false, the same reason the sheet's buy button would be. `tier` subscribed → 3.4, because Manage already keys on `tier`. The contract says a fourth value "is not coming"; this is defensive.
- **Trial at the day boundary.** `trial_ends_at` is `now + 14 days` at INSERT (`models/family.py:37-43`, `TRIAL_DAYS` in `constants.py:112`), an instant that falls mid-day; the admin lever can write a midnight-UTC one. "Until {day}" names the calendar day that instant falls on for the reader, and "until" stays true either side of the boundary where "through" would not. On the named day the missions can stop partway through while the card still reads "Until 17 Sep"; the gate is the server's, the card re-reads on foreground and on appearance, and the pin in section 5 item 6 guarantees the header follows `access` and never the date.
- **Purchase mid-flight.** Header keeps the server's word; busy row in the CTA slot; Restore disabled. `.late` and `.awaitingApproval`: reported row in the CTA slot, no CTA, Restore enabled. A grant landing during `.confirming` keeps the busy row (today's ordering, pinned by `aGrantDoesNotHideFinishingUp`), and a grant landing during `.late` keeps the reported row for the same reason; Restore is hidden in both, because the household is a member. `.failed` after the sheet was swiped away: rows return, the store's sentence under the card.
- **Billing retry.** The date line is off and the server sends no date, so a parent in retry is not told when membership would end if the card keeps failing; the server does not know (`gracePeriodExpiresDate` is not parsed) and a guessed date is worse than none. The Manage row names both places — the plan in the App Store, the payment method in the paying Apple Account's settings — because Apple's sheet reaches only the first.
- **Two guardians, one just subscribed.** The other phone's foreground re-read flips the header from "Free trial" to "Annual membership" and removes both rows in one render; `boardNeedsReload` is unchanged.

## 10. Open decisions for the owner

1. The date, not a count: agreed, or do you want the number despite section 5?
2. Headline for a paying household: the plan noun ("Annual membership") or the approved word ("Subscribed") with the plan moving into the detail?
3. API: `expires_at` and the exact `auto_renew` together (recommended; no migration), or `expires_at` alone with "Paid through {date}. Whether it renews is set in the App Store." as every subscriber's default line?
4. Billing retry: say D7 in the header and R4r on the row, or stay silent as today?
5. Lapsed: identical to free, or add the optional "Previous membership / Ended {date}" row?
6. Free detail: the one approved sentence (D2), or the post-trial notice's two ("The daily question keeps going, free, forever. The missions are part of membership whenever you want them.")? The second resolves the "MEMBERSHIP … Free" skim but is two long sentences in a one-line slot; taking it means widening `SettingsCardHeader`'s described detail, which is a design-system change rather than a call site.
7. No household yet: keep the offer row as shipped, or Restore only?
8. "Managed by the other parent." as written, or reworded?
9. The two complimentary sentences (D8, D9) as written, or reworded?
10. The trial's charge, named on the card (R2t) — and whether the paywall should say it too. The sheet today renders "Subscribe" and "$59.99 a year" with `renewalTerms` ("Membership renews automatically until cancelled. Cancel any time in your Apple Account settings.") and nothing about the trial; a one-clause addition there ("You're charged when you join; …") is a sheet change outside this card and is named here rather than assumed.
11. R4′ replacing the shipped Manage detail for every subscriber, or only where `is_payer` is null?
12. D10 and D11 as written, or reworded — and whether "—" stays as the headline above them.
13. U5′ replacing the shipped "Nothing has arrived yet…" sentence, model-side.

## 11. Risks that remain

- The owner asked for a number and gets a date. If "13 days left" is what he pictures, this will feel like it dodged him; it did not, but he should decide with that named.
- "Free trial" over "Until 17 Sep 2026" is still a clock to a nervous parent. It does not tick, and "No card, nothing to cancel." sits beside it, but it is a real bet that the pairing reads as reassurance rather than a deadline.
- `is_payer` null is the common case, and R4′ is a sentence, not a fix: the invited parent still sees a Manage row whose sheet is empty on their phone. The card tells them why before they tap; it cannot stop them tapping.
- "Paid through" with its pointer is the render whenever the ledger's last payload carried no `autoRenewStatus`: every `SUBMITTED` row until the next notification, and any pre-existing row whose stored payload lacks `renewalInfo`. Rare after the first renewal, but it is the first thing a fresh subscriber who arrived by submission will read.
- With today's API the subscribed header answers "am I paying?" (yes, annual) and not "until when?", which was the owner's exact ask. Until the API half lands, the date is one tap away in Apple's sheet.
- R2t names a charge on a receipt. It is a fact and it is calm, but it is the first sentence on this card that mentions money, and a parent on day one may read "You're charged when you join" as pressure rather than as the warning it is. The paywall still says nothing about it (open decision 10).
- D7 is the first sentence on this surface that names a payment that did not go through. "Couldn't take the last payment" is softer than "failed" and is followed by "will try again" and "carries on", but some parents will still feel it; and the retry parent gets no date, because the server has none to give. Silence is compliant and loses nothing structural.
- "MEMBERSHIP" over "YOUR HOUSEHOLD" over "Free" can be skimmed as "membership is free" before D2 and the CTA correct it. The two-sentence detail that would resolve it in one glance does not fit the slot (open decision 6).
- U5 under a Free card tells a never-paid parent that something is on its way. U5′ fixes it in one clause and changes a shipped string.
- Lapsed and never-subscribed are indistinguishable on purpose; a returning parent gets no acknowledgment that they used to pay.
- A parent whose Apple ID bought under a different Pocket Chronicle account still sees "Free" and "Become a member" first; the explanation appears only after they tap Restore. That is phase 143's state, and this card routes to it rather than solving it.
- "Complimentary membership" tells a granted household what it has, not why. This card is not the place for that sentence and there is no approved one.
- "—" is still the headline in both unknown states. D10 and D11 give it a sentence; the dash itself is the approved word for not-known and stays unless the owner wants a word there.
- Two terracotta rows on the non-member card weaken "one status, one action" slightly; the alternative, Restore only on the paywall, makes the Sep 2 parent tap "Become a member" holding a paid receipt, which is worse.
- `SettingsCardHeader` gets its first call site here. If its semantics ever change for the card it was drawn for, this card inherits the change.

## Critique responses

Findings applied as written are not listed. Where a finding was applied by a different route, or not applied, one line each:

- **Confused-parent, `.late` / `.awaitingApproval` (major):** applied — reported row in the card, CTA hidden, Restore enabled — and one step further than asked: `purchaseLine` stops returning U1/U2, because a sentence rendered in the card must not also render under it. `aGrantDoesNotHideFinishingUp`'s `.late → .hidden` assertion changes as a consequence, in the spirit of its other two.
- **Confused-parent, trial CTA (major):** applied as R2t, without the second `{date}` the critic's string carried: the header two lines up already names the day, and a constant with no placeholder is simpler to register. The sheet-side sentence is open decision 10 rather than an assumed change, because the sheet is outside this card.
- **Confused-parent, unknown state (major):** applied, with a different nil-household sentence. The critic's "Couldn't check with the server just now" is false for the first second of every visit, when the read is running rather than failed, and the pure function cannot tell the two apart; D10 was written to be true in both. D11 is the critic's sentence with "everything stays available" replaced by "nothing is held back", since "everything … open" is the phrase the brief opened with.
- **Confused-parent, "Paid through" (major):** applied by both of the critic's routes at once — the two fields ship together so the neutral line is the rare fallback, and D5p follows it where the Manage row is.
- **Confused-parent, billing retry wording (major):** the header rewrite applied verbatim for the first two sentences; the third moved to the Manage row (rules-and-honesty's destination finding), and the non-payer variant was dropped rather than composed, on my judgment: the sentence is an offer to fix and that parent cannot fix it, and the three-sentence cell it produced was the longest detail on the card for the rarest state.
- **Confused-parent, "Free" detail (minor):** not applied. The two-sentence notice is the paragraph the rules-and-honesty finding on the detail slot rules out, and I will not widen a design-system slot to resolve a skim. Kept as open decision 6 with the tension stated, and in §11.
- **Confused-parent, day boundary (minor):** applied (the §9 sentence, the foreground re-read, the pin in §5 item 6); the end-of-day API change is named as not requested rather than proposed.
- **Confused-parent, U5 for the curious parent (minor):** applied as U5′, an owner option in §4 and §6 and a line in §11, since it changes a shipped model string.
- **Rules-and-honesty, detail slot (major):** applied — every detail is one or two short sentences; D1 lost its third sentence to R2t, D7 lost its third to R4r. No `detailRole: .body` requested; the design-system entry gains one clarifying clause, not a new role.
- **Rules-and-honesty and engineer, `auto_renew` derivation (minor):** applied by a route neither finding named, having verified it in the tree: the decoded `renewalInfo.autoRenewStatus` is already in `raw_payload` for every notification row (`app_store.py:433`, `test_app_store.py:234`), so the field is exact from a JSONB path in the existing select, with no migration, no over-report and no flap. Both findings' fallback options are superseded rather than chosen.
- **Rules-and-honesty, offer under unrecognised `access` (minor):** applied; the earlier draft's D9 reasoning was wrong for the reason the finding gave, and the offer now keys on `!isMember` everywhere, which is also the engineer's request that the switch be written out.
- **Engineer, pre-121 `.subscribed`-with-`tier`-free cell (major):** answered `.offer`, today's behaviour, under an H5 headline, and named as the phase-141 contradiction on a server that is not serving rather than fixed; fixing it would mean keying the offer on `access`, which the previous finding just removed.
- **Engineer, D7 as two constants (minor):** moot under the restructure — D7 is two sentences in one constant and nothing is split at runtime; the fix sentence is its own constant on the Manage row (R4r).
- **Engineer, `expires_at` null during grace (major):** applied, including the `billing_retry` condition and the injectable clock; the grace test is rewritten with a future `expires_date` on the fixture, as the finding specified.