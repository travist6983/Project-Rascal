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

## 4. Checking it worked

```bash
curl -s https://rascal-api.fly.dev/health                       # {"status":"ok","db":"ok"}
curl -so /dev/null -w '%{http_code}\n' https://rascal-api.fly.dev/admin              # 200
curl -so /dev/null -w '%{http_code}\n' https://rascal-api.fly.dev/v1/admin/snapshot  # 401
```

The last one **should** be 401 — the page is public, the data is not.

Signed in, the Costs tab shows one card per provider: connected ones report figures, the rest
name the variable they want. The Studio's provider strip does the same.
