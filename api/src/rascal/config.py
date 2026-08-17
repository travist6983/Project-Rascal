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
    mail_from: str = "Dogear <hello@rascal.local>"
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

    # Browser origins allowed to call the subscribe route. **A list from the first commit**,
    # because a scalar is a thing a second origin has to migrate off — and the marketing site
    # will have a custom domain beside its github.io one. Never `*`, and applied to that route
    # alone rather than globally: this is the first browser client this API has ever had.
    marketing_origins: Annotated[list[str], NoDecode] = ["https://travist6983.github.io"]

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
