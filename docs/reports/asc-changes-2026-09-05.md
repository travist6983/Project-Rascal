# App Store Connect changes — Sep 5, 2026

Two settings changes made (per explicit instruction), two read-only checks. App: PocketChronicle.App,
bundle id `com.travisterry.childarchive`. Signed in as the account already authenticated in Chrome —
no credentials entered. Nothing else on the account was touched; no Add for Review, Submit, Clear
Purchase History, or Send Test Notification button was pressed anywhere in this pass.

## 1. Billing Grace Period — changed

Before: Off (no grace period configured — "Set Up Billing Grace Period" prompt only).

After: **On** — Grace Period Duration `16 days`, Eligible Subscribers `All Renewals`, Server
Environments `Production and Sandbox Environment`.

Note: the dialog carries a third choice (Server Environments) that wasn't in the original
instructions — I paused and asked before saving, since "Sandbox only" vs. "Production and Sandbox"
changes whether this affects real subscribers. You chose Production and Sandbox, so it's live for
active subscribers now, not just sandbox testers. Saving required a second confirmation dialog
("Turn On Billing Grace Period in Production?"), which I accepted per your instruction.

Screenshot: `08-grace-period-on.png`

## 2. Streamlined Purchasing — attempted, blocked by Apple

Before: Turned On.

After: **Still Turned On — the change could not be made.** Selecting "Turn Off Streamlined
Purchasing" and clicking Save returned this error from Apple:

> Streamlined purchasing cannot be turned off because your latest approved binary doesn't include
> the required StoreKit APIs.

This isn't a permissions or process issue on my end — App Store Connect refused the save outright.
Per the dialog's own explanation, turning this off requires your latest **approved** binary to
include specific StoreKit APIs for completing purchases in-app; build 23 (currently in review)
apparently doesn't qualify, or no build has been approved yet to carry that flag. Nothing was saved;
the dialog was cancelled cleanly, no other field was touched.

Screenshot: `09-streamlined-off.png` (shows the blocking error, not an "off" state)

## 3. App Store Promotion — read only

Checked: the annual subscription page, the monthly subscription page, the In-App Purchases list
page, and the iOS App 1.0 version page (where Apple's "Promoted In-App Purchases" section normally
lives).

**Result: no App Store Promotion / Promote / Promotional Image control exists anywhere for either
subscription right now.** Neither product page. Both individual subscription pages do mention that
uploading an Image (Optional) "will also appear on your app's product page" if App Store Promotion
is enabled elsewhere, but neither has an image set (`–`), and no separate toggle or section to
enable that promotion was found on any page checked, including the app's In-App Purchases list
(currently empty — no items exist there at all, since the two products live under Subscriptions,
not In-App Purchases). Likely this section only appears after a subscription has actually been
approved/released; as of today, both are still Waiting for Review, so nothing to report on except
its absence for annual and monthly alike.

## 4. Previews and Screenshots — read only

iOS App 1.0 → App Store tab → Previews and Screenshots → Media Manager. Seven device sizes are
listed under "iPhone"; only one has its own uploaded set, the rest explicitly say "Using 6.5"
Display" (Apple auto-fills them from that set rather than requiring separate uploads):

| Device size | Screenshots present | Source | Required marker shown |
|---|---|---|---|
| iPhone 6.5" Display | 10 | Uploaded directly | None |
| iPhone 6.3" Display | 10 | Using 6.5" Display | None |
| iPhone 6.1" Display | 10 | Using 6.5" Display | None |
| iPhone 5.5" Display | 10 | Using 6.5" Display | None |
| iPhone 4.7" Display | 10 | Using 6.5" Display | None |
| iPhone 4" Display | 10 | Using 6.5" Display | None |
| iPhone 3.5" Display | 10 | Using 6.5" Display | None |

No size showed a "required"/missing badge or warning banner — all seven read as fully covered. This
contradicts the Aug 29 doc's "0 of 10, required" note; screenshots have since been uploaded (the
10 files are named `01-today.png`, `02-timeline.png`, `03-moments.png`, `08-detail-voice.png`,
`11-detail-text.png`, `18-filter-voice.png`, `09-detail-video.png`, `10-detail-did-it.png`,
`19-filter-sealed.png`, `05-detail-photos-nine.png`).

Screenshot: `10-screenshots.png` (the primary 6.5" Display set; the fallback sizes were confirmed by
expanding each one on screen, not separately captured)

## Summary table

| # | Item | Before | After | Screenshot |
|---|---|---|---|---|
| 1 | Billing Grace Period | Off | On — 16 days, All Renewals, Production and Sandbox | `08-grace-period-on.png` |
| 2 | Streamlined Purchasing | Turned On | Turned On (unchanged — Apple blocked the turn-off) | `09-streamlined-off.png` |
| 3 | App Store Promotion (annual) | n/a (read only) | Not configured — no such control found | — |
| 3 | App Store Promotion (monthly) | n/a (read only) | Not configured — no such control found | — |
| 4 | Previews and Screenshots | n/a (read only) | 10/10 present for all 7 listed device sizes, no required markers | `10-screenshots.png` |
