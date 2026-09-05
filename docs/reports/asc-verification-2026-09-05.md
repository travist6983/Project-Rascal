# App Store Connect verification — what to bring back

**Written Sep 5, 2026.** This is the answer sheet for the Claude Cowork prompt at the bottom of this
file. Cowork reads App Store Connect; nothing here changes anything. Fill the **Read** column with the
value exactly as the page shows it, mark **PASS** or **MISMATCH** against the expected value, and
attach one screenshot per row, named as in the last column.

Why each row exists: the API has never processed a Production App Store notification. All three
rows in the production ledger are Sandbox. The first real customer is the first time the Production
branch runs, so the settings it depends on get read back now rather than discovered then.

**Filled in Sep 5, 2026, by Claude (Cowork), read-only.** Signed in as the account already
authenticated in Chrome (Travis Terry / Travis Justin Terry) — no credentials entered. No Save,
Add for Review, Clear Purchase History, Delete Account, or Send Test Notification button was
pressed anywhere in this pass; every "Edit" dialog opened for reading was closed with Cancel.

## 1. The app record

| # | Setting | Where | Expected | Read | PASS / MISMATCH | Screenshot |
|---|---|---|---|---|---|---|
| 1a | Production Server URL | General → App Information → App Store Server Notifications | `https://rascal-api.fly.dev/v1/webhooks/app-store` | `https://rascal-api.fly.dev/v1/webhooks/app-store` | PASS | `01-server-urls.png` |
| 1b | Production Server URL version | same | Version 2 | No version selector exists in the Edit dialog — the URL is a single field with no V1/V2 choice. Apple's current UI only supports the V2 notification schema, so this endpoint is V2 by construction; there's no separate value to read. | PASS (by absence of a V1 option) | (same) |
| 1c | Sandbox Server URL | same | blank **or** the same URL as 1a. Any other URL is MISMATCH | `https://rascal-api.fly.dev/v1/webhooks/app-store` (identical to Production) | PASS | (same) |
| 1d | Sandbox Server URL version | same | Version 2 if set | Same as 1b — no version field shown, single URL only | PASS | (same) |
| 2 | Apple ID (numeric) | General → App Information → General Information | `6800155810` | `6800155810` | PASS | `02-app-information.png` |
| 3 | Bundle ID | same | `com.travisterry.childarchive` | `com.travisterry.childarchive` | PASS | (same) |

## 2. Subscriptions

| # | Setting | Where | Expected | Read | PASS / MISMATCH | Screenshot |
|---|---|---|---|---|---|---|
| 4a | Subscription group name | Monetization → Subscriptions | `Membership` | `Membership` (2 subscriptions in group, ID 22332670) | PASS | `04-subscriptions.png` |
| 4b | Annual product id | inside the group | `com.travisterry.childarchive.subscription.annual` | `com.travisterry.childarchive.subscription.annual` (reference name "Membership Annual", Apple ID 6804841108) | PASS | (same) |
| 4c | Monthly product id | inside the group | `com.travisterry.childarchive.subscription.monthly` | `com.travisterry.childarchive.subscription.monthly` (reference name "Monthly Membership", Apple ID 6804841469) | PASS | (same) |
| 4d | State of each product | same | report as shown (Ready to Submit / Waiting for Review / Approved) | Both **Waiting for Review** (group itself also shows Waiting for Review, with an "Add for Review" button greyed out, i.e. already submitted) | n/a | (same) |
| 5 | Billing Grace Period | Monetization → Subscriptions → Billing Grace Period | **report on/off, and the duration if on.** No expected value; see note below | **Off** — the section shows only a "Set Up Billing Grace Period" prompt, nothing configured | n/a | `05-grace-period.png` |
| 6a | Family Sharing, annual | open the annual product | Off | **Off** — the field shows a "Turn On" link, meaning it is not currently enabled | PASS | `06-annual.png` |
| 6b | Family Sharing, monthly | open the monthly product | Off | **Off** — same "Turn On" link shown, not enabled | PASS | `06-monthly.png` |
| 6c | Introductory offer, annual | same product page | report whether one is configured, and its terms | **None configured** — "Current Pricing for New Subscribers" table shows "Introductory Offers (0)" across all 175 countries/regions | n/a | (same, see `06-annual-intro-offers.png`) |
| 6d | Introductory offer, monthly | same | report | **None configured** — same table shows "Introductory Offers (0)" | n/a | (same, see `06-monthly-intro-offers.png`) |

**Note on row 5.** The server handles both settings and the choice is the owner's, not a defect
either way. With the grace period **off**, Apple sends `DID_FAIL_TO_RENEW` with no subtype at the
first failed charge and the household reads Free that day. With it **on**, Apple sends the
`GRACE_PERIOD` subtype, the household keeps everything while Apple retries the card, and access ends
only at `GRACE_PERIOD_EXPIRED`. Report what is set so the contract can say which one is true.

**Confirmed: grace period is currently off**, so per the contract logic above, `DID_FAIL_TO_RENEW`
with no subtype is the notification the server should expect at first failed charge, and the
household should read Free that same day rather than staying entitled through a grace window.

Also noted in passing on the Subscriptions page (not one of the requested rows): **Streamlined
Purchasing is Turned On**.

## 3. Sandbox testers (read only — do not clear anyone's purchase history)

Users and Access → Sandbox → Testers. One row per tester. Mask the email to its first two
characters plus the domain.

| Tester (masked) | Subscription Renewal Rate | Interrupted Purchases | Notes |
|---|---|---|---|
| tr...@gmail.com | Monthly renewal every 5 minutes | Off (checkbox unchecked — purchases are not being interrupted) | Region: United States. Apple Pay: Yes. |

Only one sandbox tester exists ("Test Accounts (1)"). Region shown: **United States**. No tester on
this page is marked as used by App Review — there is no such flag, badge, or column anywhere on the
Test Accounts list or in the tester's Edit dialog.

## 4. Anything else on screen

- **The app has moved forward since the Aug 29 state doc**: it now reads **"iOS 1.0 Waiting for
  Review"**, not "Prepare for Submission." App Review → Submissions shows one completed submission:
  submitted Wednesday at 9:43 PM, iOS 1.0, 4 Items, submitted by Travis Terry, status Waiting for
  Review. This is one of the two states the prompt says not to flag, but it's a real state change
  worth registering — the production webhook path could see traffic sooner than expected.
- The app tile on the Apps list carries a red exclamation badge and a "View App Review Issues &
  Messages" link. This turned out to be routine chrome for an app currently in review, not a flagged
  problem — the linked page shows only the submission record above, no messages or issues from Apple.
- A persistent, non-dismissed banner reads: **"Review New Social Media Questions on Age Ratings —
  See if these new questions about social media capabilities apply to your app in the App Information
  section."** This is a generic Apple-wide reminder, not specific to this app, and isn't an
  "action needed" badge tied to a real deficiency, but it hasn't been dismissed or actioned yet.
- Digital Services Act status is unchanged from the Aug 29 doc: **"This developer has identified
  itself as a non-trader for this app,"** Active — matches the deliberate decision not to publish a
  home address until a PO Box exists.
- China Mainland ICP Filing Number, Vietnam Game License, and Regulated Medical Device declaration
  are all still unset/not applicable — no change, nothing actioned.
- App Encryption Documentation still shows the standing "You can provide your documentation before
  you submit a build" / Upload prompt (this is the permanent optional affordance, not a blocker —
  build 23, the one currently in review, is itself "Waiting for Review" rather than "Missing
  Compliance").
- In passing, on the iOS App Version 1.0 page (reached while locating the Subscriptions link),
  the Previews and Screenshots section still showed only a bare "iPhone" placeholder with no
  thumbnails, and the attached build is **Build 23**, version 1.0, App Clip: No. I did not
  deliberately audit the screenshot count for this report — flagging it only because it lines up
  with the Aug 29 doc's "0 of 10, required" item and the app is now Waiting for Review, which is
  worth a second look before this goes further.
- No agreement or banking notices, no other "action needed" badges, appeared anywhere else visited
  (App Information, Subscriptions, both individual subscription pages, Sandbox Testers).

Screenshot of the app home page (Apps list): `00-home.png`.

## What each answer leads to

- **1a–1d MISMATCH:** set the Production Server URL to the expected value, Version 2. Until then the
  only thing that promotes a real purchase is the phone's own receipt submission, and nothing tells
  the server about renewals, cancellations or refunds.
- **2 MISMATCH:** the deployed `APP_STORE_APP_APPLE_ID` is wrong. First purchases still land, but
  every later Production notification is refused with 401 and a cancelled household stays subscribed.
  Fix is one Fly secret.
- **3 MISMATCH:** stop and report; the verifier pins the bundle id and nothing would verify.
- **5:** recorded in `docs/api-contract.md` beside the `DID_FAIL_TO_RENEW` rows, whichever it is.
- **6a/6b MISMATCH:** Family Sharing is rejected by D4. Turn it off; the server never reads
  `inAppOwnershipType` and a shared receipt would be refused with 409.
- **6c/6d:** if an introductory offer exists, `docs/blocked.md` §10 step 5 says it must not; the
  server-side trial is the free period. Report; do not remove it from Cowork.

All rows above are PASS or match the documented, safe state (1a–4c, 6a, 6b), and rows without a
PASS/MISMATCH verdict (4d, 5, 6c, 6d) are reported as requested with no expected value to violate.
Nothing here requires the `APP_STORE_APP_APPLE_ID` fix, the Family Sharing turn-off, or the
introductory-offer removal described above — those branches don't apply this pass.

## The prompt this file answers

```
I need you to verify App Store Connect settings for my iOS app and report back before changing
anything. Read-only. Fill in the file docs/reports/asc-verification-2026-09-05.md in this
repository: every "Read" cell, every PASS / MISMATCH cell, the sandbox tester table, and the
"Anything else on screen" section. Save one screenshot per row into docs/reports/asc-2026-09-05/
with the file names the table gives.

Sign in to App Store Connect (appstoreconnect.apple.com) and open the app whose bundle id is
com.travisterry.childarchive. The "Where" column names destinations, not click paths; if a page has
moved, find it by name and note where it actually lives.

Do not edit, save, submit, or clear anything. If a page offers a "Clear Purchase History", "Send
Test Notification" or similar button, do not press it.
```
