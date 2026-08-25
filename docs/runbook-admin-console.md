# Runbook — the admin console

`/admin`, both locally and at `https://rascal-api.fly.dev/admin`. Phases 96–98.

Two independent things: **getting in**, and **switching the panels on**. The console works with
no keys at all — Today and Ops read the database — so do the first part and add keys as you want
the panels.

---

## 1. Getting in

The console is a page holding a bearer token. It has no session of its own and no cookie.

### Locally

`make dev`, then <http://localhost:8000/admin> → **Sign in with dev-login**. That route exists
only when `ENVIRONMENT=local` and it grants `is_admin`, so nothing else is needed.

### In production — two one-time steps first

**`dev-login` does not exist in production**, and nothing in the codebase sets `is_admin` except
`dev-login`. So the first production admin has to be made by hand, in the Neon SQL editor.

**Find your account.** A Sign in with Apple account's `email` is usually a
`privaterelay.appleid.com` address, so search credentials rather than guessing:

```sql
SELECT u.id, u.email, u.display_name, u.is_admin,
       c.provider, c.subject_id, c.revoked_at
FROM users u
LEFT JOIN credentials c ON c.user_id = u.id
ORDER BY u.created_at;
```

**Make yourself an admin.**

```sql
UPDATE users SET is_admin = true WHERE id = '<your-user-id>';
```

**Give yourself an email sign-in method**, if the query above shows no active `email` row for
you. `POST /auth/email/start` only sends to an address that already has a credential and it is
not revoked — that is deliberate, so the endpoint cannot be used to discover who has an account.

```sql
INSERT INTO credentials (id, user_id, provider, subject_id, revoked_at)
VALUES (gen_random_uuid(), '<your-user-id>', 'email', 'you@example.com', NULL);
```

`revoked_at NULL` means active. Adding it through the app instead
(`POST /v1/me/credentials/email`) creates it *inactive* and the confirmation click activates it;
inserting it directly skips that because you are already proving control of the row.

### Then, every time

On the console's sign-in screen:

1. Type your address, **Send link**.
2. Open the email and click the link. It lands on a page saying *"Open this on your iPhone"* —
   **ignore that**, it is copy for parents. Copy the whole URL out of the address bar.
3. Paste it into the second box and **Sign in**.

The console pulls the token out of the URL, exchanges it, and keeps the refresh token — so it
stays signed in for 30 days rather than the access token's 15 minutes. Sign-in links are single
use and expire in 15 minutes.

If you already have an access token from somewhere else, the third box takes it directly — but
that route has no refresh token behind it, so it lasts 15 minutes and then drops you out.

---

## 2. The keys

Nothing below is required. Each one switches on a panel and each missing one shows a card naming
the variable, so you can add them in any order.

### Local — append to `.env` at the repo root

```bash
cat >> .env <<'EOF'

# --- Admin console ---
ANTHROPIC_API_KEY=sk-ant-api...
ANTHROPIC_ADMIN_KEY=sk-ant-admin...
GITHUB_BILLING_TOKEN=github_pat_...
GITHUB_ACCOUNT=travist6983
FLY_API_TOKEN=FlyV1 ...
FLY_APP_NAME=rascal-api
NEON_API_KEY=napi_...
NEON_PROJECT_ID=...
NEON_ORG_ID=org-...
RESEND_AUDIENCE_ID=...
EOF
```

Restart `make dev` afterwards — settings are read once at startup.

### Production

```bash
flyctl secrets set -a rascal-api \
  ANTHROPIC_API_KEY='sk-ant-api...' \
  ANTHROPIC_ADMIN_KEY='sk-ant-admin...' \
  GITHUB_BILLING_TOKEN='github_pat_...' \
  FLY_API_TOKEN='FlyV1 ...' \
  NEON_API_KEY='napi_...' \
  NEON_PROJECT_ID='...' \
  NEON_ORG_ID='org-...'
```

Setting a secret restarts the machines — one deploy, not seven, so set them in a single command.
`FLY_APP_NAME` already defaults to `rascal-api` and `RESEND_AUDIENCE_ID` is already set there.

> **Never set `ADMIN_READ_DATABASE_URL` on Fly.** It exists so a laptop can read production; in
> production the console already reads Neon through `DATABASE_URL`, and setting it would make
> the deployed console read-only for no benefit.

### Where each value comes from

| Variable | Where | Unlocks |
|---|---|---|
| `ANTHROPIC_API_KEY` | platform.claude.com → API keys | Studio: chat, concepts, shot lists |
| `ANTHROPIC_ADMIN_KEY` | platform.claude.com → Settings → **Admin keys** | Costs: dollars, tokens, cache hit rate |
| `GITHUB_BILLING_TOKEN` | github.com → Settings → Developer settings → Fine-grained tokens → **Account permissions → Plan → Read-only** | Costs: Actions spend, the second real dollar figure |
| `GITHUB_ACCOUNT` | the username that owns the bill — defaults to `travist6983` | Costs: whose bill |
| `FLY_API_TOKEN` | `fly tokens create readonly` | Costs: machines, guests, volumes, stale-image detection |
| `NEON_API_KEY` | console.neon.tech → Account settings → API keys | Costs: storage and compute |
| `NEON_PROJECT_ID` | console.neon.tech → project → Settings | Costs: which project |
| `NEON_ORG_ID` | console.neon.tech → in the URL | Costs: the daily compute chart, and nothing else |
| `RESEND_AUDIENCE_ID` | resend.com → Audiences | Costs: subscribers. Also unblocks `POST /v1/subscribe` |
| `GEMINI_API_KEY` | aistudio.google.com → API keys, **on a project with billing enabled** | Studio: rendering a shot list into video |

### The two Anthropic keys cannot be the same value

`ANTHROPIC_API_KEY` is an ordinary `sk-ant-api…` key. `ANTHROPIC_ADMIN_KEY` is an
`sk-ant-admin…` key, provisioned separately. The docs are explicit that the Admin API accepts
**only** an Admin API key or an `org:admin` OAuth token, so a normal API key cannot read the
cost report. They are two keys, not one key used twice.

> **Admin keys do not exist on individual accounts.** *"The Admin API is unavailable for
> individual accounts"*, and only organization members with the admin role can provision one.
> If Console → Settings has no **Admin keys** section, you are on an individual account and the
> Anthropic cost card cannot work until you set up an organization
> (Console → Settings → Organization). **Nothing else in the console depends on it** — the
> Studio uses `ANTHROPIC_API_KEY`, which every account has.

The `org:admin` OAuth token is the documented alternative to an Admin key, but it is short-lived
and refreshed interactively, so it is not a value to put in a Fly secret.

### The Gemini key needs billing, and the error will not say so

`GEMINI_API_KEY` renders a shot list into video — one generation per shot, joined with ffmpeg.
It is optional; without it the Studio's render button refuses and everything else works.

> **The video models have a free-tier quota of exactly zero.** A key that answers text
> requests perfectly returns **429** for video, and Google's message reads *"You exceeded
> your current quota"* — which sounds like rate limiting and is actually billing. The tell is
> in the detail: `generate_content_free_tier_requests, limit: 0`. If you see `free_tier` in
> that string, the project is not on a paid tier however many credits the console shows.

**Credits on a different project do not count.** API keys belong to a project, and billing has
to be enabled on *that* project. Check which tier the key is actually on at
[ai.dev/rate-limit](https://ai.dev/rate-limit) — it names the tier directly, which is faster
than reading a 429 twice. Propagation after enabling is minutes, not instant.

**Every video model on this API is preview**, and the `veo-3.0`/`veo-2.0` ids most search
results still name were shut down on June 30, 2026 — confirmed absent from a live model list.
`GEMINI_VIDEO_MODEL` is a setting so a moved id is a secret change rather than a deploy.

### After billing, the next refusal is not about money — and it decided the default model

**Billing was enabled Aug 21, 2026 and the section above stopped being the last hurdle.** The
first render past the 429 came back **200** and then refused a shot: `gemini-omni-flash-preview`
rejected **a static shot of a photograph, captioned *"Why did you take this one?"*, as "harmful
content"**. It is ordinary product copy, there is nothing to appeal, and every Veo 3.1 tier
accepts the identical prompt byte for byte.

**So the default is `veo-3.1-lite-generate-preview`.** Two things follow that matter when you are
sitting in front of the console:

- **Renders take minutes and the number is real.** Veo is asynchronous — the service starts an
  operation, polls it, then downloads the clip — and one four-second Lite clip measured **about
  ninety seconds**. A seven-shot treatment is seven of those plus a concatenation. The panel polls
  `shots_done` of `shots_total`; it is working, not hung. The ceiling is eight minutes **per
  clip**, after which the render is failed deliberately and the clips already paid for are kept.
- **The price changed with the model, and you have to change it too.** Lite is **$0.05 a second**
  against Omni Flash's $0.10 ($0.40 for Veo Standard), so `GEMINI_VIDEO_CENTS_PER_SECOND` is `5`.
  **If you repoint `GEMINI_VIDEO_MODEL` and leave the price, the console confidently prices the
  wrong model.** Nothing detects this — it is two independent settings by design, because the
  price is a figure somebody typed, and it has **never been reconciled against a Google invoice**.

**Omni Flash still works if you set it** — the service speaks both API shapes and picks by the
model id prefix. It is worth trying again if the filter loosens, because it remains the only model
documenting legible on-screen text, which every captioned shot needs.

### The GitHub billing token is not the token CI uses

Two separate mistakes lead to the same dead end here, and both produce a **404**.

`GITHUB_BILLING_TOKEN` must be a **fine-grained** personal access token whose Account
permission **Plan** is set to **Read-only**. The repo-scoped classic token that CI holds reads
repositories; this endpoint reads the *account's plan*, which is a different thing entirely and
which no amount of `repo` scope grants.

> **A token without `Plan: read` gets 404, not 403.** That is the whole trap. A bare "not
> found" reads as a mistyped username, and the obvious next move — checking and re-checking
> `GITHUB_ACCOUNT` — is the wrong one. The card says so on its face for this reason.

**The endpoints that most search results describe no longer exist.**
`/users/{u}/settings/billing/actions`, `/shared-storage` and `/packages` were removed rather
than deprecated, along with every field they returned (`total_minutes_used`,
`included_minutes`, `minutes_used_breakdown`). The current path is
`/users/{u}/settings/billing/usage`, and it requires the account to be on the enhanced billing
platform — which is what a **403** here means, as opposed to the 404 above.

**The card shows no minutes-remaining gauge, on purpose.** The billing API exposes no budget,
no quota and no remaining balance. A $0 budget with "stop usage" enabled rejects every run
before its first step — which is what halted this repository twice, per `blocked.md` §0 and
§0a — and nothing in this response would have moved beforehand. A gauge reading *"0 of 2,000
minutes used"* would have shown green through both. Check
[the budgets page](https://github.com/settings/billing/budgets), which the card links to.

### Optional

```bash
OPENAI_API_KEY=sk-...                    # Studio: photographic images
REPLICATE_API_TOKEN=r8_...               # Studio: images and video
REPLICATE_IMAGE_MODEL=<version-string>   # Replicate pins by version, not by name
REPLICATE_VIDEO_MODEL=<version-string>
STORAGE_PRICE_CENTS_PER_GB_MONTH=2       # Costs: a storage estimate, labelled as yours
APPLE_MEMBERSHIP_CENTS_PER_YEAR=9900     # Costs: the membership, amortised over twelve months
SOCIAL_FEATURED_PROMPT_CAP=24            # How many library prompts may go public. See D7
```

Brand cards need none of these — they are drawn in the browser.

**The two price settings are the only figures on the costs screen that a vendor did not send.**
Anthropic and GitHub report money themselves. Tigris and Apple publish no billing API at all,
so their cards carry a number only because one was typed here — and each says so on its face,
naming the variable it came from. Unset is the honest default and produces a card with no
dollar figure rather than one reading `$0.00`.

---

## 3. Reading production from your laptop

```bash
ADMIN_READ_DATABASE_URL=postgresql://console_reader:...@ep-....neon.tech/rascal?sslmode=require
```

The console's read routes follow it; `make migrate`, `make seed`, `make test` and `make reset-db`
keep talking to localhost, which is the entire point — `make reset-db` runs
`alembic downgrade base`. While it is set the console is read-only and says so in the top bar.

Make a read-only role in the Neon SQL editor first:

```sql
CREATE ROLE console_reader WITH LOGIN PASSWORD 'pick-something';
GRANT CONNECT ON DATABASE rascal TO console_reader;
GRANT USAGE ON SCHEMA public TO console_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO console_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO console_reader;
```

The connection also sets `default_transaction_read_only=on`, so writes are refused even with a
full-access role. The role is the belt; that is the braces.

---

## 3a. Seeing the free tier — the trial lever

~~*the one entitlement lever*~~ — **struck Aug 24, 2026 by phase 121, which added a second
one.** This section is the *trial*; §3b below is *grants*. Both reach entitlement and neither
touches `tier`.

**Today tab → *Membership — move a household's trial*.** Pick the household, pick a date, press
**Set trial**. **Clear trial** removes the date entirely.

| What you want | What to do | What `access` becomes |
|---|---|---|
| See the free tier — one item on the board, the rest locked | Set the date to **yesterday** | `free` |
| Go back to a full board | Set the date to **next month** | `trial` |
| A household with no trial at all | **Clear trial** | `free` |

**Every row above assumes `tier` is `free`, and yours is not.** `subscribed` beats `trial`, so a
subscribed household reads `access: "subscribed"` whatever this lever writes — the date is stored
and will matter the day the subscription lapses, but the board does not change. `runbook-deploy.md`
§7a wrote `tier = 'subscribed'` for your own household by hand and says it *"always will be"*, so
**to see the free tier you have to undo that first**:

```sql
-- runbook-deploy.md §7a in reverse. Put it back afterwards or you cannot mint an invite.
UPDATE entitlements SET tier = 'free'
WHERE family_id = (SELECT family_id FROM users WHERE email = '<your email>');
```

The console says so too, at the moment it happens: setting a trial on a subscribed household
reports *"Saved, but access stays subscribed — the tier outranks the trial."* rather than implying
it worked.

The *Newest accounts* table above it shows `Access` beside `Tier`, so you can read the result
without reloading the app. They answer different questions and both are shown deliberately:
**`Tier` is whether Apple has told us somebody is paying; `Access` is what a phone will actually
be served today.** During a fourteen-day trial those are different answers, and a console showing
only `Tier` would make a trial look like a lapse.

**The date you pick is the last day of the trial.** It is stored as the end of that day in your
own timezone, so picking today leaves the household entitled for the rest of today rather than
dropping it the moment you save.

**This lever cannot set the tier, and there is deliberately no control that can.** D5 reserves
`entitlements.tier` for App Store Server Notifications V2 and a test asserts it has exactly one
writer; a button here that set it would be a person disagreeing with Apple about who is paying.
Moving `trial_ends_at` reaches both states without going near that column, which is the whole
reason this is the lever. If you genuinely need to make a household `subscribed`, that is still
`docs/runbook-deploy.md` §7a — a hand-run SQL statement, deliberately not a button.

**A grant will also hide the free tier from you, and since phase 121 the response says so.** An
active `entitlement_grants` row reads `access: "subscribed"` exactly as a paid tier does, so the
paragraph above about *"a household already on subscribed will not move"* now has two possible
causes. The confirmation line names which: it reads *"a grant is holding this household open —
revoke it in Grants below"* rather than sending you to §7a for a tier that was never the reason.

**It is hidden while `ADMIN_READ_DATABASE_URL` is set.** The console is reading production and
writing to your local database in that state, so a control that appeared to work and did not would
be worse than no control. Unset it to edit locally, or use the deployed console.

**The effect is immediate on the next `GET /today`** — the read repairs the day it finds, so a
household you re-entitle at 2pm gets its missions on the next pull rather than tomorrow morning.
Going the other way, the mission rows that already exist are **not deleted**; they stop being
served and go on existing, and they come back if you re-entitle.

---

## 3b. Grants — entitling a household without a payment

**Today tab → *Grants — entitle a household without a payment*.** Added by phase 121.

A founding tester, a refund made good, a family who should not be paying. A grant entitles a
household exactly as a subscription does — full board, and the guardian invite unlocked — and
**it does not touch `tier`**. The household goes on reading `tier: "free"` and starts reading
`entitled: true`; both are true sentences, and `entitlement_source` on the wire says which of the
two is holding the door open.

### Issuing one

1. **Find a household.** Type an email, a display name, or a family id into *Find a household*.
   The picker searches account metadata only — nothing here can reach a child's name or anything
   in an archive. An empty box lists the most recent households.
2. **Pick it in the *Household* dropdown.** The label carries the short family id and the current
   access state, because two accounts can share a display name and picking the wrong one grants
   the wrong household.
3. **Write a reason.** Required, free text: `founding tester`, `refund goodwill`, `press`. A blank
   one is refused — the reason is the only thing that makes the ledger worth having in six months.
4. **Set an end date, or leave it empty.** *Empty means no end date*, which is a real state rather
   than a missing one. The date you pick is the **last day** the grant covers, stored as the end of
   that day in your own timezone — the same rule the trial date follows.
5. **Issue grant.**

**A date already in the past is refused** rather than written: the row would be inactive from the
moment it was saved, sitting in the ledger looking like a grant.

### Extending somebody

**Issue a second grant.** There is deliberately no edit: extending is a new row, the old one stays,
and the two together are the history. The household is entitled until the *longest* of them runs
out, and that is the date the wire reports.

### Revoking

**Revoke** on the row. It takes effect on the next read — every entitlement surface computes the
answer per request, so there is nothing to wait for and no cache to clear. Revoking twice is a
success and writes nothing the second time.

**The row stays.** There is no delete and no route that could issue one: the record of who you gave
something to, why, and when you took it back is the part a support conversation actually needs. A
revoked row reads `REVOKED` in the ledger and stops entitling immediately.

### The `By` column, and when it is empty

`By` is whoever pressed the button, taken from the bearer token and never from the request. It
reads **`account deleted`** when that account has since been erased — account deletion hard-deletes
`users` rows, and the alternative to letting this go null was either destroying the ledger row with
the account (`ON DELETE CASCADE`) or making somebody's erasure request fail (`RESTRICT`). The grant
itself survives and goes on entitling; only the name is gone.

### While `ADMIN_READ_DATABASE_URL` is set

**The ledger still renders and the form does not.** Read-only mode replaces the form with a
sentence naming the variable, and the *Revoke* buttons go with it. That is deliberately different
from the Membership card above, which disappears entirely: half of this card is a *read*, and
"who already has one of these" is usually the question you are in read-only mode to answer.

Unset `ADMIN_READ_DATABASE_URL` to issue or revoke against the database this process reads, or use
the deployed console.

### Checking it by hand

```bash
TOKEN=...   # an is_admin access token; the console's dev-login button mints one locally
curl -s -H "Authorization: Bearer $TOKEN" localhost:8000/v1/admin/grants | jq
curl -s -H "Authorization: Bearer $TOKEN" 'localhost:8000/v1/admin/households?q=someone@example.com' | jq
```

And from the household's side — this is the pair worth reading together, because it is the whole
phase in two lines:

```bash
curl -s -H "Authorization: Bearer $PARENT_TOKEN" localhost:8000/v1/families/me \
  | jq '{tier, access, entitled, entitlement_source, grant_expires_at}'
# { "tier": "free", "access": "subscribed", "entitled": true,
#   "entitlement_source": "grant", "grant_expires_at": null }
```

---

## 4. Checking it worked

```bash
curl -s https://rascal-api.fly.dev/health                       # {"status":"ok","db":"ok"}
curl -so /dev/null -w '%{http_code}\n' https://rascal-api.fly.dev/admin              # 200
curl -so /dev/null -w '%{http_code}\n' https://rascal-api.fly.dev/v1/admin/snapshot  # 401
```

The last one **should** be 401 — the page is public, the data is not.

Signed in, the Costs tab shows one card per provider: connected ones report figures, the rest
name the variable they want. The Studio's provider strip does the same.

And the entitlement lever, from a shell rather than the page — useful when you want to check the
answer the phone will get rather than the one the console draws:

**The timestamp must carry an offset.** An offset-less one — `2026-09-01T00:00:00` — is
refused with a `422` naming the field, deliberately: assuming UTC for a value a person typed is
this service inventing a timezone, and a naive timestamp in an archive spanning eighteen years
is the bug that surfaces years later. `Z` or `+13:00`, either is fine.

```bash
# Drop a household to the free tier. `access` comes back `free`; `tier` is untouched.
curl -s -X PUT "$API/v1/admin/families/$FAMILY_ID/trial" \
  -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"trial_ends_at": "2020-01-01T00:00:00Z"}'

# What the phone sees: one item in `today`, the rest of the day in `locked`.
curl -s "$API/v1/children/$CHILD_ID/today" -H "Authorization: Bearer $TOKEN" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["access"], [i["slot"] for i in d["today"]], [i["slot"] for i in d["locked"]])'
```
