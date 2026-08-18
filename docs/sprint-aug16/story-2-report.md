# Story 2 — the capture form. Report.

**Repo touched:** `travist6983/Rascal-Marketing` only. No phase number is consumed: this is
marketing-site work, and the roadmap ledger numbers API and iOS lane phases.

## The story's contract was wrong in three ways, and the shipped one was used instead

Story 2 was written before phase 60 landed, and it specifies an endpoint that does not exist.
Gate 1 says to confirm the contract and not to guess, so it was read out of
`api/src/rascal/routers/subscribe.py` on `main`.

| Story 2 says | `main` actually has |
|---|---|
| `POST /v1/subscribers` | `POST /v1/subscribe` |
| `{ email, source }` | `{ email, turnstile_token, source }` |
| A honeypot is the whole defence | Turnstile is the defence; the honeypot is a cheap addition |
| We own confirmation tokens and three landing pages | Resend owns double opt-in; we store nothing |

The third row is the one that changed the shape of the work, so it is spelled out below.

## Three behaviours that look obvious and are wrong against this route

1. **There is no duplicate state, and the form must not invent one.** The route answers `202`
   for every outcome that is not an outage — new, already subscribed, already unsubscribed, all
   identical — because any other answer makes it an oracle that tells anyone with a browser
   whether a given address is on the list. The previous script had a `409` branch and a
   "You're already on the list" line. Both are gone. The page cannot know that and must not
   guess it.
2. **The old success state was a lie.** It said *"You're in. First prompt lands tomorrow
   morning."* Nothing is stored by us and the contact is unconfirmed until they click Resend's
   email, so the confirmation email contradicted that sentence within the minute. It now says to
   check the inbox.
3. **The two hidden consent inputs were deleted.** `marketing_consent` and
   `transactional_consent` were there for D3a's two-flags-not-one-flag rule, but there is no
   `subscribers` table and the server ignores both fields. A consent flag posted into nowhere is
   worse than no flag: to anyone auditing the form it reads as consent being recorded. D3a comes
   back on the day the list comes in-house.

## Landing pages — two, not three

- **`/thanks` became the confirmed page** rather than a new `confirmed.html` beside it. It
  already existed, already said "You're on the list", and nothing linked to it. That sentence is
  true exactly once — after somebody clicks the confirmation link — so that is now the only page
  allowed to say it, and the form no longer navigates there.
- **`/unsubscribed` is new.** One line, no win-back, no "are you sure?", per the story. It also
  states the suppression list in the same breath as the confirmation, because finding that out
  later reads like something that was hidden.
- **`confirm-error.html` was deliberately not built.** It describes our confirmation token
  failing, and we have no confirmation token — Resend owns that flow and renders its own error.
  Nothing in the system can produce a link to that page. Building it would mean shipping a page
  no URL reaches, describing a mechanism that does not exist.

## What ran, and what is reasoned

**Observed.** The form was driven in Chrome against a local stub and Cloudflare's public test
site key (`1x00000000000000000000AA`), served from a throwaway copy of `dist/`:

| Path | Result |
|---|---|
| Happy path | `POST /v1/subscribe`, body keys exactly `email`, `source`, `turnstile_token`, real token, `source: "/waitlist"` |
| Success state | Form replaced with "Check your inbox — there is a link to confirm." |
| Honeypot filled | Success state shown, **zero requests reached the stub** |
| Malformed address | Inline message, `aria-invalid="true"`, nothing sent |
| Server returns non-2xx | One calm line in `--ink-muted` (not red), button label restored, form intact, retry possible |
| No site key (today's state) | "Signups are not open yet — nothing was sent", **and the Cloudflare script never loads** |

**Reasoned, not observed.** The real `rascal-api.fly.dev` was never called, so the deployed
route, its CORS response to the GitHub Pages origin, and a genuine Turnstile verification are
unverified. This does not work end to end and nobody should say it does until it has been
exercised once against the deployed API from the real origin.

## Owner errand this adds

**Create a Turnstile widget and put its site key in `SIGNUP.TURNSTILE_SITE_KEY` in
`src/assets/site.js`.** It is a public key and belongs in the markup; it is not
`TURNSTILE_SECRET_KEY`, which is the server's and is already on the blocked list. Until it is
set the form explains itself and posts nothing, which is deliberate — the server fails closed on
a missing token, so a form that posted anyway would only ever show an error.

Also still outstanding, and both already on the list: `MAIL_API_KEY` (full access) and
`RESEND_AUDIENCE_ID`, without which the route returns `503` and the form shows its calm error.

## Privacy page, again

Story 5 deliberately left the Turnstile disclosure out so the page was true at every commit.
It lands here, with the form, plus two corrections the form itself forced:

- *"There is no second form and no hidden field"* became false the moment a honeypot existed.
  The hidden field is now described, including that it is never transmitted.
- The Turnstile paragraph says plainly that **right now it does not load at all**, because no
  site key is set. Asserting a third party runs when it does not is the same class of error the
  story 5 audit existed to fix.

`npm run build && npm run check`: 21 pages, 0 warnings, 0 failures.
