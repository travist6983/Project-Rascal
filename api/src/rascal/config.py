"""Application settings, read once from the environment at import time."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Annotated, Literal

from pydantic import field_validator, model_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict

# api/src/rascal/config.py -> api/src/rascal -> api/src -> api -> repo root
REPO_ROOT = Path(__file__).resolve().parents[3]


def _split_csv(value: object) -> list[str]:
    """A comma-separated environment value as a list, stripped and compacted.

    Already-a-list passes through, so a `Settings(**model_dump())` round trip is stable and a
    test can hand in either shape.
    """
    raw = value if isinstance(value, list | tuple) else str(value).split(",")
    return [item for item in (str(entry).strip() for entry in raw) if item]


class DatabaseSettings(BaseSettings):
    """Just enough configuration to open a connection, and nothing else.

    Alembic and the seed job are not the API. A migration needs a database; it does not need
    an S3 bucket, AWS credentials, or an Apple bundle id. Requiring those would mean any
    context that only migrates — the pre-flight workflow against Neon, a restore drill, a
    one-off shell — has to invent five values it will never use, and inventing them is how a
    real misconfiguration gets papered over. `Settings` extends this, so the connection
    fields are still declared exactly once.
    """

    model_config = SettingsConfigDict(
        env_file=REPO_ROOT / ".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    database_url: str
    # Optional second connection string, used only by Alembic. Neon's pooled endpoint is
    # PgBouncer in transaction mode, which does not support the session-level machinery a
    # migration needs — advisory locks, prepared statements, some DDL. The app wants the
    # pooler; migrations want the direct endpoint. Unset locally, where there is no pooler.
    direct_database_url: str | None = None

    @property
    def sync_database_url(self) -> str:
        """What Alembic connects with. psycopg3 drives both sync and async off one scheme.

        Prefers `DIRECT_DATABASE_URL` when set, because a migration run through a
        transaction-mode pooler fails in ways that read like anything but the real cause.
        """
        return self.direct_database_url or self.database_url


class Settings(DatabaseSettings):
    """Every knob the service has. Missing required keys fail loudly at startup."""

    environment: Literal["local", "prod"] = "local"

    jwt_secret: str

    s3_bucket: str
    s3_region: str
    aws_access_key_id: str
    aws_secret_access_key: str

    # Any S3-compatible endpoint. RASCAL stores media on Tigris, which speaks S3 but is not
    # AWS, so the client has to be pointed at it explicitly — the credential names stay
    # AWS-shaped because that is the protocol's convention, not because Amazon is involved.
    # `None` means real AWS, which is exactly how this behaved before Tigris, so an existing
    # deployment that never sets it is unaffected. See docs/tigris-setup.md.
    s3_endpoint_url: str | None = None

    # **A list, and the name is deliberately unchanged.** One Apple credential can be issued to
    # more than one audience — the iOS app is one, and a browser client signing in through a
    # Services ID is a second — and `aud` is the only claim that tells them apart. Renaming the
    # setting would mean rotating a Fly secret on a live app to buy nothing.
    #
    # Written as a comma-separated string in the environment; a single value stays a single
    # value and is exactly what production has always set. `NoDecode` is load-bearing:
    # pydantic-settings would otherwise try to JSON-decode a complex type read from the
    # environment, and `com.travisterry.childarchive` is not JSON.
    apple_bundle_id: Annotated[list[str], NoDecode]

    # Token lifetimes. Fixed by docs/api-contract.md; here so tests can reason about them.
    access_token_ttl_minutes: int = 15
    refresh_token_ttl_days: int = 30

    # Apple's JWKS is stable for hours; a per-request fetch would be a self-inflicted outage.
    apple_jwks_url: str = "https://appleid.apple.com/auth/keys"
    apple_issuer: str = "https://appleid.apple.com"
    apple_jwks_cache_seconds: int = 3600

    # --- Google -----------------------------------------------------------------------------
    #
    # **A separate audience list from Apple's, and a list from day one.** `aud` is a claim name
    # both providers happen to share; the values are different namespaces and pooling them
    # would mean an Apple token for a Google client id verifying, which is a hole rather than
    # a convenience.
    #
    # Defaults to empty, because no Google project exists yet and making it required would
    # stop every current deploy from starting. Empty means `POST /auth/google` refuses with a
    # message naming the setting, rather than rejecting every real token for no stated reason.
    google_client_ids: Annotated[list[str], NoDecode] = []
    google_jwks_url: str = "https://www.googleapis.com/oauth2/v3/certs"
    # **Both spellings are valid and both are seen**, which is why this is a list and Apple's
    # issuer is a string. Google's own documentation names them as alternatives.
    google_issuers: Annotated[list[str], NoDecode] = [
        "accounts.google.com",
        "https://accounts.google.com",
    ]
    google_jwks_cache_seconds: int = 3600

    @property
    def google_configured(self) -> bool:
        return bool(self.google_client_ids)

    # Anything at or under this goes out as a single presigned PUT; above it, multipart.
    multipart_threshold_bytes: int = 15 * 1024 * 1024
    multipart_chunk_bytes: int = 8 * 1024 * 1024
    presign_ttl_seconds: int = 3600

    assignment_expiry_days: int = 14

    # --- dev-login ------------------------------------------------------------------------
    #
    # Which email domains the local fixture login will mint a session for, comma-separated.
    #
    # The route is already local-only — `main.py` mounts it inside `if settings.is_local`, so
    # it does not exist in a production build. This is the second lock, and it closes a
    # different hole from the first: a developer pointing a local API at a *real* database,
    # which happens during a restore drill or a production debugging session, could otherwise
    # type their own address and be handed an `is_admin` session for the live account. The
    # gate that stops that is one the environment cannot be wrong about.
    dev_login_email_domains: Annotated[list[str], NoDecode] = ["rascal.local"]

    # --- Magic-link sign-in ---------------------------------------------------------------
    #
    # **The universal-link landing path, not the API endpoint.** `/auth/email/complete` is a
    # POST route; a link pointing there would 405 in any browser. The app claims `/signin` via
    # the association file, pulls the token out, and posts it to the real endpoint itself.
    email_sign_in_link_base: str = "https://rascal-api.fly.dev/signin"

    # --- The household invite link ---------------------------------------------------------
    #
    # **Where an emailed invite points**, and its own setting for exactly the reason
    # `email_sign_in_link_base` is one: the host a mail links to and the host this API answers
    # on are the same today and are not the same thing. The token is appended as a path
    # segment, because that is the shape `/invite/{token}` is claimed in the association file
    # and the shape the client already builds (`GuardiansModel.shareURL`).
    #
    # No trailing slash — `invite_link` joins it with one.
    invite_link_base: str = "https://rascal-api.fly.dev/invite"

    # Half of the `appID` in the association file — `<team>.<bundle>`. Not a secret: it is
    # printed in every provisioning profile and is served publicly at `/.well-known/` by
    # design. A default rather than a required value, because a wrong one here breaks
    # universal links silently and a missing one would break startup for every deploy.
    apple_team_id: str = "8976QYWNC2"

    # Rate limits for `POST /auth/email/start`, the one unauthenticated endpoint that sends
    # mail. **Per-email is the one that matters** — the abuse is spamming links at one address,
    # and an edge limiter cannot see the address because it is inside the body.
    #
    # Five an hour is generous for a real parent who mistyped and retried, and useless as a way
    # to fill somebody's inbox. Per-IP is looser because a household behind one NAT is normal.
    email_sign_in_per_email_limit: int = 5
    email_sign_in_per_ip_limit: int = 20
    email_sign_in_window_seconds: int = 3600

    # --- Mail -----------------------------------------------------------------------------
    #
    # **`console` is the default and it is a safety property, not a convenience.** It writes
    # the whole message to stdout and never opens a socket, so a local run cannot send real
    # mail to a real person — which matters more here than in most services, because the
    # addresses this will eventually hold belong to parents and the messages are about
    # deleting their child's archive.
    mail_provider: Literal["console", "resend"] = "console"
    mail_api_key: str | None = None
    mail_from: str = "Pocket Chronicle <hello@rascal.local>"
    # Unset means replies go to `mail_from`.
    mail_reply_to: str | None = None
    mail_timeout_seconds: float = 10.0

    # --- Marketing: the signup endpoint, per D7, D8 and open item 12 -----------------------
    #
    # **Every value here is optional at import**, which is the rule `docs/runbook-deploy.md` §4
    # states and the reason it exists: these are set by hand *after* a merge, and a
    # required-at-import key means an unattended deploy crash-loops on a value nobody has typed
    # yet. A missing value has to degrade to a refusal at the route, never to an import error.
    #
    # **`turnstile_secret_key` unset means the endpoint refuses**, and that is the whole design.
    # `roadmap-status.md` names the opposite — skipping verification when the key is missing —
    # as *the* defect to design against, because it is the one that leaves the health check
    # green while a public write endpoint stands wide open. Turnstile is the entire protection
    # here: there is no rate limit on this route, by the owner's call of Aug 16, 2026.
    #
    # Cloudflare publishes test keys that always pass, which is what a local run uses — a
    # bypass for `ENVIRONMENT == "local"` would be a second way through the gate, and the
    # second way is always the one that survives into production by accident.
    turnstile_secret_key: str | None = None
    turnstile_verify_url: str = "https://challenges.cloudflare.com/turnstile/v0/siteverify"
    turnstile_timeout_seconds: float = 10.0

    # The Resend audience the signup forwards into. **There is no `subscribers` table** — the
    # list is provider-held per open item 12(4), so this id is where a subscriber actually
    # lives. Unset means the route refuses rather than accepting an address it cannot store.
    resend_audience_id: str | None = None

    # --- Double opt-in (phase 87) ---------------------------------------------------------
    #
    # **Where the marketing site lives.** One setting, two consumers: the confirmation link
    # sends a browser back here after the click, and the daily broadcast's footer links here.
    #
    # It replaces a hardcoded `SITE_URL = "https://travist6983.github.io"` that sat in
    # `services/broadcast.py` and went stale the day the custom domain landed — every prompt
    # email's footer would have pointed at a URL that now only redirects. A constant that names
    # somebody else's deployment target is a constant that rots silently.
    marketing_site_url: str = "https://pocketchronicle.app"

    # Where the confirmation link points. Its own setting rather than derived from anything,
    # for the reason `email_sign_in_link_base` is: the host that mail links to and the host the
    # API answers on are the same today and are not the same thing.
    subscribe_confirm_link_base: str = "https://rascal-api.fly.dev/v1/subscribe/confirm"

    # **Short on purpose, and not for secrecy.** The token is signed, so age does not weaken it.
    # It is short because a confirmation link stays good for its whole life — see
    # `services/subscribe_token.py` — and the expiry is the only thing bounding a stale link
    # that is reopened after an unsubscribe.
    subscribe_confirm_ttl_days: int = 7

    # **The switch that lets the daily broadcast actually send, and it defaults to off.**
    #
    # ~~Open item 12 says it in every line that touches this work: *no marketing email sends
    # before the P0 behavioural gate*, which is seven days of unforced daily use and has not
    # started.~~ — **the gate was lifted by the owner on Aug 22, 2026 and the flag is set in
    # production.** The reason the flag exists is unchanged and is the half worth keeping: a
    # job that would send the moment credentials appeared would turn setting a secret into
    # mailing strangers, and nobody setting a secret expects that. It defaults to off for
    # that reason, not for the gate's.
    #
    # Off, the job does everything except the network call: picks the prompt, renders both
    # bodies, writes the ledger row as `skipped`, and logs what it would have sent. Flipping
    # this to true is the entire difference, and there is no code change behind it.
    marketing_email_enabled: bool = False

    # **The hour the daily prompt goes out, in `broadcast_timezone`.** 8am, because the prompt
    # asks a parent to notice something *today* and one that lands at 8pm has already missed it.
    #
    # **The machine runs hourly and this decides which run acts** — `jobs/notify.py` established
    # that shape and says why: *"hourly is the floor Fly gives, not the resolution this wants."*
    # A `--schedule daily` machine fires roughly when it was created, which would tie the send
    # time to the minute somebody happened to run `fly machine run`.
    #
    # **A run outside the hour writes no ledger row**, which is the property that matters: a row
    # claims the day, so an off-hour run that recorded `skipped` would silently cancel that day's
    # send.
    broadcast_send_hour: int = 8
    broadcast_timezone: str = "America/Detroit"

    # Browser origins allowed to call the subscribe route. **A list from the first commit**,
    # because a scalar is a thing a second origin has to migrate off — and the marketing site
    # will have a custom domain beside its github.io one. Never `*`. ~~and applied to that route
    # alone rather than globally~~ — **struck Aug 28, 2026: that scoping does not exist.** The
    # middleware is added app-wide; what keeps authenticated routes out of reach is
    # `allow_headers=["Content-Type"]`, which refuses a preflight carrying `Authorization`.
    # `main.py` carries the full note and is the single place the scoping is described — do not
    # restate it here. This is the first browser client this API has ever had.
    # **`https://pocketchronicle.app` added Aug 27, 2026 (phase 131).** The custom domain this
    # comment anticipated now exists and serves the marketing site, so a browser calling
    # `POST /v1/subscribe` from it sends that Origin. Without it here the subscribe form is
    # refused by the browser while every test stays green, because no test exercises CORS.
    # ⚠️ **`MARKETING_ORIGINS` is a Deployed Fly secret on `rascal-api`**, which overrides this
    # default entirely — so this edit does NOT reach production. The deployed value must be set
    # to include the new origin by hand. See `docs/blocked.md` §13.
    #
    # **`MARKETING_SITE_URL` is NOT a secret** — checked against `flyctl secrets list -a
    # rascal-api`, which holds `MAIL_FROM`, `MARKETING_ORIGINS` and `MARKETING_EMAIL_ENABLED` and
    # no site URL — so its default *is* what production reads and phase 131's edit ships on the
    # next deploy. The two settings look alike and behave differently; check the list rather than
    # assuming, which is the mistake that produced an earlier draft of this comment.
    marketing_origins: Annotated[list[str], NoDecode] = [
        "https://pocketchronicle.app",
        "https://travist6983.github.io",
    ]

    # --- The admin console's cost panel (phase 96, extended by phase 100) ------------------
    #
    # **Every one of these is optional, and unset is the shipped state.** They are read-only
    # credentials for somebody else's billing API, and the panel's whole design is that a
    # missing one produces a card that names the environment variable and where to get the
    # key — never a 500, and never a blank space that reads as "$0 spent".
    #
    # They are deliberately *not* reused from anywhere else in this service. `MAIL_API_KEY`
    # is the exception and is not duplicated here: the Resend card reads the key the mailer
    # already has, because a second copy of one credential is a second thing to rotate.
    #
    # Read-only is a property to preserve when minting these. Nothing in the console writes
    # to a provider, so a token with write scope buys nothing and costs a blast radius.

    #: An Anthropic **Admin** key — `sk-ant-admin…`, minted at platform.claude.com under
    #: Settings → Admin keys, not a normal `sk-ant-api…` key. Only an admin key may read
    #: `/v1/organizations/cost_report`; an ordinary API key answers 401 there, which is the
    #: confusing failure this comment exists to pre-empt.
    anthropic_admin_key: str | None = None

    #: A GitHub **fine-grained** personal access token whose only permission is Account
    #: permissions → **Plan → Read-only**. Not a classic token, and not the repo-scoped token
    #: CI already holds: this endpoint reads the account's plan rather than a repository.
    #:
    #: **A token without Plan:read gets 404, not 403**, which is the whole reason this comment
    #: exists — a bare "not found" reads as a mistyped username and sends you renaming the
    #: account instead of regenerating the token.
    github_billing_token: str | None = None

    #: The personal account the bill belongs to. The path is
    #: `/users/{account}/settings/billing/usage`, so this is a username, never a repository.
    github_account: str = "travist6983"

    #: A Fly.io API token — `fly tokens create readonly` is enough for the machine inventory,
    #: which is what this card is actually for. Fly does not expose per-app spend over the
    #: API, so the card reports machines, regions and schedules rather than inventing a
    #: dollar figure. See `services/billing/fly.py`.
    fly_api_token: str | None = None
    fly_app_name: str = "rascal-api"

    #: Neon's API key (console.neon.tech → Account settings → API keys) and the project it
    #: should read. Neon reports consumption — storage bytes, compute seconds, egress — and
    #: not dollars, so that is what the card shows.
    neon_api_key: str | None = None
    neon_project_id: str | None = None

    #: The Neon organisation the project belongs to. **Required by the v2 consumption endpoint
    #: and by nothing else** — the project snapshot needs only the project id, so leaving this
    #: unset costs the daily compute chart and nothing more. Found in the console URL. It is
    #: deliberately not derived at runtime from `GET /users/me/organizations`: that would be a
    #: request per render spent parsing a response shape to guess at, in place of one variable.
    neon_org_id: str | None = None

    #: What object storage costs per GB-month, in cents, on the plan we are actually on.
    #: **Unset means the card shows bytes and no estimate**, which is the honest default:
    #: Tigris has no billing API, so any figure here is one somebody typed, and a made-up
    #: number on a costs page is worse than a blank one.
    storage_price_cents_per_gb_month: int | None = None

    #: The Apple Developer Program membership, in cents per year — `9900` at the published US
    #: price. **The only money Apple charges this project**, and it is not retrievable from any
    #: API: App Store Connect is free to call and publishes no billing endpoint at all. Unset
    #: means the card shows the pre-launch sentence and no figure, which is correct until
    #: somebody types the number they actually paid.
    apple_membership_cents_per_year: int | None = None

    #: How long a provider's answer is reused before the console asks again. These are other
    #: people's rate limits, and a dashboard left open in a tab must not poll six vendors on
    #: every render. In-process rather than in Postgres on purpose: the data is cosmetic, a
    #: second Fly machine holding a slightly different cache costs nothing, and a cache table
    #: would be schema for a screen.
    billing_cache_seconds: int = 300
    billing_timeout_seconds: float = 12.0

    # --- Looking at production from a laptop (phase 98) ------------------------------------
    #
    # **A second connection for the admin console's read routes, and nothing else.**
    #
    # The obvious way to point the console at Neon is to change `DATABASE_URL`, and it is a
    # trap. That variable is read by `make migrate`, `make seed`, `make reset-db` — which runs
    # `alembic downgrade base` — and `make test`, which drops and recreates `<db>_test`. Aimed
    # at Neon, every one of those becomes a command that destroys the archive, sitting in a
    # Makefile one tab-completion away. `dev_login_email_domains` above describes the other
    # half of the same hazard.
    #
    # So the console gets its own address and nothing else in the service learns it. Unset —
    # the shipped state — the console reads whatever `DATABASE_URL` points at, exactly as
    # before.
    #
    # **Set it and the console becomes read-only**, in three independent ways: the connection
    # sets `default_transaction_read_only=on` so Postgres refuses writes outright, the write
    # routes refuse before they reach a session, and the top bar says which database is on
    # screen. Use a read-only Neon role as well; that is the belt, this is the braces.
    #
    # Paste the string Neon gives you. `postgres://`, `postgresql://` and `postgresql+psycopg://`
    # are all accepted — `services/readonly_db.normalise` rewrites the scheme, because the
    # failure it prevents names neither the setting nor the fix.
    admin_read_database_url: str | None = None

    @property
    def admin_reads_elsewhere(self) -> bool:
        """Whether the console is looking at a database this process cannot write to."""
        return bool(self.admin_read_database_url)

    # --- The social studio (phase 97) ------------------------------------------------------
    #
    # **`anthropic_api_key` is an ordinary `sk-ant-api…` key and is NOT `anthropic_admin_key`
    # above.** They are different kinds of key from the same console and neither works in the
    # other's place: the admin key reads organisation billing and cannot call `/v1/messages`;
    # this one calls `/v1/messages` and cannot read billing. Two settings rather than one
    # because collapsing them would mean a 401 whose message named the wrong thing.
    #
    # `scripts/generate_prompts.py` has read this same variable since phase 46, so a checkout
    # that can already generate prompt candidates can already run the studio.
    anthropic_api_key: str | None = None

    #: Overridable because the right model for this changes faster than this file does. The
    #: default is Opus rather than the Sonnet the candidate generator picks: that script writes
    #: hundreds of rows a human filters, this one writes a handful that go out under the
    #: product's name.
    anthropic_model: str = "claude-opus-5"

    #: The model the console's prompt-candidate generator uses, kept separate from the studio's
    #: on the owner's call of Aug 20, 2026 (phase 103). Same argument `director.DEFAULT_MODEL`
    #: makes in the other direction: candidates are volume a human filters on the spot, so
    #: Sonnet is the right trade, while the studio writes a handful of things that go out under
    #: the product's name. One setting rather than a shared one so moving either does not move
    #: the other — which is exactly what a single `ANTHROPIC_MODEL` would have done.
    anthropic_candidates_model: str = "claude-sonnet-5"

    # --- Pixel renderers -------------------------------------------------------------------
    #
    # **Anthropic has no image or video endpoint on any model**, so photographs and footage
    # need a second vendor and there is no configuration that makes the key above produce one.
    # All optional; unset means the Studio shows a card naming the variable rather than a
    # button that fails. The brand-card renderer needs none of these — it draws in the browser.
    openai_api_key: str | None = None
    replicate_api_token: str | None = None
    #: Version strings rather than model names: Replicate pins by version, and a name would
    #: silently start rendering something else the day the model was updated.
    replicate_image_model: str | None = None
    replicate_video_model: str | None = None

    # --- Instagram publishing (phase 104) -------------------------------------------------
    #
    # **The account is shared with the marketing repository**, by the owner's decision of
    # Aug 20, 2026: @getvellum.app, one feed, two publishers. That is the fact that shapes the
    # settings below. `Rascal-Marketing`'s hourly workflow posts from a committed queue and
    # this service posts from the console, and neither can see the other's database — so the
    # spacing and the daily count here are read from **Instagram**, never from our own
    # `social_publications` rows.
    # A limit computed from our own rows would be a limit that does not know about half the feed.
    #
    # Meta moves the API version and the permission names more often than anything else this
    # service talks to, which is why the host and version are settings rather than constants:
    # correcting them is a secret change and not a deploy.
    #
    # **`IG_` rather than `INSTAGRAM_` deliberately**: these are the names the marketing
    # repository's workflow already uses for the same two secrets, and one credential with two
    # names in two places is how a rotation updates one of them.
    ig_user_id: str | None = None
    ig_access_token: str | None = None
    #: `graph.instagram.com` is the Instagram-Login flow, which needs no Facebook Page.
    #: `graph.facebook.com` is the Facebook-Login flow. Verified against the live account on
    #: Aug 20, 2026: the token in use is the Instagram-Login kind and this host answers it.
    ig_api_host: str = "https://graph.instagram.com"
    ig_api_version: str = "v25.0"

    # **Credentials do not switch publishing on.** This is `marketing_email_enabled`'s pattern
    # and it is here for the same reason that one exists: setting a secret must never, by
    # itself, start reaching the public.
    #
    # **Unlike that one, off means refuse rather than rehearse.** `publishing._check_publishable`
    # raises before the duplicate lookup, before spacing and before any container, so nothing is
    # generated and nothing is reported. `python -m rascal.jobs.social --dry-run` is the
    # rehearsal and does not depend on this setting. The comment here used to claim the
    # broadcast job's behaviour; it was describing a sibling rather than this.
    social_publish_enabled: bool = False

    #: The smallest gap between two posts on the account, whoever made them. Instagram's own
    #: ceiling is far higher; this is about a feed that reads as written rather than as drained.
    #: The marketing poster uses 55 minutes for the same reason and the two should agree.
    social_min_gap_minutes: int = 55
    #: Meta's documented ceiling is 100 API-published posts per rolling 24 hours — it was 25
    #: until they raised it, so it is a setting rather than a constant. Counted from the
    #: account, not from our rows.
    social_daily_post_limit: int = 100
    # There is no `social_image_url_ttl_seconds` here, and there was: it claimed to govern the
    # URL handed to Meta and nothing read it. `presign_get` signs with `presign_ttl_seconds`
    # (an hour), which is the same number and is the one that actually applies — Meta fetches
    # within seconds of the container call, so the margin is enormous either way. A knob that
    # does nothing is worse than no knob: somebody eventually turns it to fix something.

    #: How many mission-library bodies may appear in social posts before the studio refuses.
    #: **This is a leak budget, not a rate limit.** D7 keeps the library out of anything
    #: public "whole or in generated slices" and calls it the one asset a competitor would
    #: want; the risk from posting prompts is cumulative and invisible, so it is counted and
    #: capped rather than trusted. Raise it deliberately, having looked at the number.
    social_featured_prompt_cap: int = 24

    # --- APNs ----------------------------------------------------------------------------
    #
    # All optional, and unset is the state this repository has always been in: the key comes
    # from the same Apple Developer portal trip as Sign in with Apple, and that enrollment is
    # still open — see docs/blocked.md §1. Unset means `build_push_client` hands back a
    # client that sends nothing and says so loudly, rather than one that pretends to succeed.
    #
    # `apns_private_key` is the *contents* of the `.p8` file, not a path. A Fly secret is a
    # string, and a path would mean shipping a key into the image.
    apns_key_id: str | None = None
    apns_team_id: str | None = None
    apns_private_key: str | None = None
    # The APNs topic is *a* bundle id — one string, never a list. It defaults to
    # `apple_bundle_id` when that holds exactly one audience, rather than being a second place
    # to get the same value wrong. With more than one audience there is nothing to default to
    # and `_apns_topic_is_unambiguous` refuses to start. See `resolved_apns_topic`.
    apns_topic: str | None = None

    # --- Sign in with Apple revocation (phase 127) -----------------------------------------
    #
    # Guideline 5.1.1(v) requires an app offering Sign in with Apple to call Apple's REST
    # token-revocation endpoint when the account is deleted. That call is authenticated with a
    # `client_secret` JWT signed with a **Sign in with Apple** key — a different `.p8` from the
    # APNs one above, from the same portal, with a different capability. The errand is
    # `docs/blocked.md` §24, and until it is run this is the state the repository has always
    # been in: unset.
    #
    # `apple_siwa_private_key` is the *contents* of the `.p8`, not a path, for exactly the
    # reason `apns_private_key` is. **Unset means revocation is skipped and said so at ERROR,
    # and the deletion still happens** — a parent who asked to be erased and was not, because a
    # key was missing, is the worse of the two failures by a wide margin.
    apple_siwa_key_id: str | None = None
    apple_siwa_private_key: str | None = None
    #: The `client_id` Apple's token endpoints expect: the audience the identity token was
    #: issued to. One string, never a list, and it defaults to `apple_bundle_id` for the same
    #: reason `app_store_bundle_id` does — a second place to get the same value wrong is worse
    #: than a default. `None` when the allowlist names several and none was chosen.
    apple_siwa_client_id: str | None = None
    apple_token_url: str = "https://appleid.apple.com/auth/token"
    apple_revoke_url: str = "https://appleid.apple.com/auth/revoke"
    #: Both Apple calls sit on a path a person is waiting on — sign-in for the exchange, the
    #: deletion job for the revoke — so neither may hang. Ten seconds matches `fetch_jwks`.
    apple_siwa_timeout_seconds: float = 10.0

    # --- App Store Server Notifications V2 (phase 37a) -------------------------------------
    #
    # **Nothing here has ever been exercised against Apple**, because no subscription product
    # exists in App Store Connect yet — `docs/blocked.md` §10 is the errand. Unset means the
    # webhook refuses every notification with 401 rather than accepting an unverified one, and
    # that is the design: the signature is the only thing standing between a stranger and
    # somebody's billing state, so there is deliberately no bypass, local or otherwise.

    #: Where the trusted Apple root certificates live, as DER `.cer` files. Defaults to the
    #: directory packaged inside `rascal` — bundled rather than fetched, because a root
    #: fetched at request time is a root an attacker who owns your DNS gets to choose.
    app_store_root_certs_dir: Path | None = None

    #: The app's numeric Apple ID, from App Store Connect. **Required to verify a Production
    #: notification** — Apple's own library refuses to build a Production verifier without it,
    #: because bundle id alone does not pin which app a payload is about. Unset is why a
    #: production deployment answers 401 until the errand in `docs/blocked.md` §10 is run.
    app_store_app_apple_id: int | None = None

    #: The bundle id a signed payload is checked against. One string, never a list, and
    #: defaults to `apple_bundle_id` for the same reason `apns_topic` does — a second place to
    #: get the same value wrong is worse than a default.
    app_store_bundle_id: str | None = None

    @property
    def resolved_app_store_bundle_id(self) -> str | None:
        """The single bundle id App Store payloads are pinned to, or `None` if it is ambiguous.

        **Falls back to `apple_bundle_id`, deliberately not to `resolved_apns_topic`.** The two
        are the same string today and are not the same thing: `APNS_TOPIC` exists so push can
        be aimed at one audience when the sign-in allowlist names several, and chaining this to
        it would mean setting the push topic silently re-pointed which app's receipts this
        service will accept.

        **`None` rather than a startup failure when `APPLE_BUNDLE_ID` names more than one
        audience**, which is where this differs from `resolved_apns_topic` on purpose. APNs
        refuses to start because push is configured and a wrong topic silently drops every
        notification. Nothing here is configured — no product exists in App Store Connect —
        so hard-failing would take the entire API down the day somebody adds a web Services ID,
        for a webhook that is already answering 401 for want of a root certificate.
        `AppStoreVerifier` treats `None` the same way it treats an empty trust store: it builds
        nothing, says so at ERROR, and refuses every notification.
        """
        if self.app_store_bundle_id:
            return self.app_store_bundle_id
        return self.apple_bundle_id[0] if len(self.apple_bundle_id) == 1 else None

    @property
    def resolved_apple_siwa_client_id(self) -> str | None:
        """The single `client_id` Apple's token endpoints are addressed with, or `None`.

        **`None` rather than a startup failure when `APPLE_BUNDLE_ID` names more than one
        audience**, which is where this follows `resolved_app_store_bundle_id` rather than
        `resolved_apns_topic`. Nothing here is configured today, so hard-failing would take the
        whole API down the day somebody adds a web Services ID — for a call that is already
        being skipped for want of a key.
        """
        if self.apple_siwa_client_id:
            return self.apple_siwa_client_id
        return self.apple_bundle_id[0] if len(self.apple_bundle_id) == 1 else None

    @property
    def apple_siwa_configured(self) -> bool:
        """Whether a `client_secret` can be signed and addressed to Apple.

        All three or none, the same argument `apns_configured` makes: a partial set is a
        misconfiguration, and treating it as "nearly working" hides which piece is missing.
        `apple_team_id` is not counted — it has a default and is not secret.
        """
        return all(
            (
                self.apple_siwa_key_id,
                self.apple_siwa_private_key,
                self.resolved_apple_siwa_client_id,
            )
        )

    @property
    def apns_configured(self) -> bool:
        """Whether a real APNs client can be built. All three or none — a partial set is a
        misconfiguration, and treating it as "nearly working" hides which piece is missing."""
        return all((self.apns_key_id, self.apns_team_id, self.apns_private_key))

    @property
    def resolved_apns_topic(self) -> str:
        """The single topic APNs is addressed with.

        Indexing `[0]` is safe rather than lucky: `_apns_topic_is_unambiguous` refuses to
        construct a `Settings` where this property would have to choose between audiences, and
        `_split_audiences` refuses to construct one with no audience at all.
        """
        return self.apns_topic or self.apple_bundle_id[0]

    @field_validator("dev_login_email_domains", mode="before")
    @classmethod
    def _split_dev_domains(cls, value: object) -> list[str]:
        """Lowercased, because a domain is case-insensitive and a guard that is not is a hole."""
        domains = [item.lower() for item in _split_csv(value)]
        if not domains:
            raise ValueError("DEV_LOGIN_EMAIL_DOMAINS must name at least one domain.")
        return domains

    @field_validator("apple_bundle_id", mode="before")
    @classmethod
    def _split_audiences(cls, value: object) -> list[str]:
        """`APPLE_BUNDLE_ID=a, b` is two audiences. Empty is not an audience at all.

        An empty list would sail through `jwt.decode(audience=[])` rejecting every token ever
        issued, and would leave `resolved_apns_topic` with nothing to return — a blank or
        comma-only value is a half-filled `.env` or an unset CI secret, and the only useful
        reading of it is to fail here rather than at the first sign-in.
        """
        audiences = _split_csv(value)
        if not audiences:
            raise ValueError("APPLE_BUNDLE_ID must name at least one audience.")
        return audiences

    @field_validator("marketing_origins", mode="before")
    @classmethod
    def _split_marketing_origins(cls, value: object) -> list[str]:
        """`MARKETING_ORIGINS=https://a, https://b` is two origins.

        Empty is permitted and means the subscribe route allows no browser origin at all —
        which is a refusal a deploy can see, rather than a wildcard nobody notices. **Never
        expand an empty list to `*`**: that turns a half-filled `.env` into an API any page on
        the internet may call from a browser.
        """
        return _split_csv(value)

    @field_validator("google_client_ids", "google_issuers", mode="before")
    @classmethod
    def _split_google_lists(cls, value: object) -> list[str]:
        """Empty is permitted here, unlike Apple's — an unconfigured Google is a real state.

        `google_configured` is what the route reads, so empty produces a refusal that names
        the setting rather than a token rejection that names nothing.
        """
        return _split_csv(value)

    @model_validator(mode="after")
    def _apns_topic_is_unambiguous(self) -> Settings:
        """Two audiences and no `APNS_TOPIC` is a misconfiguration, not a default.

        The wrong topic is worse than no topic: the app starts, every push is rejected with
        `DeviceTokenNotForTopic`, and nothing in any log names the audience list as the cause.
        Silently taking `[0]` would pick correctly today and incorrectly the day the order of a
        comma-separated secret changes, which is not a failure anybody would think to look for.
        """
        if self.apns_topic is None and len(self.apple_bundle_id) > 1:
            raise ValueError(
                "APNS_TOPIC must be set when APPLE_BUNDLE_ID names more than one audience "
                f"(got {self.apple_bundle_id}). The APNs topic is one bundle id and cannot be "
                "guessed from a list."
            )
        return self

    @field_validator("s3_endpoint_url", mode="after")
    @classmethod
    def _blank_endpoint_is_unset(cls, value: str | None) -> str | None:
        """`S3_ENDPOINT_URL=` means AWS, not an endpoint named empty string.

        A blank value is what a half-filled `.env` or an unset CI secret produces, and boto3
        given `""` fails in a way that names neither. Treating it as unset is the only reading
        that is ever useful.
        """
        return value.strip() or None if value else None

    @property
    def is_local(self) -> bool:
        """Gates dev-login and the /debug routes. Nothing else may branch on environment."""
        return self.environment == "local"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]


@lru_cache(maxsize=1)
def get_database_settings() -> DatabaseSettings:
    """For the connection alone. The app itself always goes through `get_settings`, so a
    missing `JWT_SECRET` still fails at startup rather than at the first request."""
    return DatabaseSettings()  # type: ignore[call-arg]
