"""Pointing the console at another database, without pointing anything else at it.

The bug this exists to prevent is not subtle and it already happened once: the console showed
six rows of local fixtures and they were indistinguishable from six real customers, so somebody
went looking for an account that had never been in that database. The fix has two halves and
both are tested here.

**The console can read somewhere else** — `ADMIN_READ_DATABASE_URL`, its own connection, over
which Postgres refuses writes.

**Nothing else learns that address.** `make migrate`, `make seed`, `make test` and
`make reset-db` all read `DATABASE_URL`, and `make reset-db` runs `alembic downgrade base`. If
the console's target ever leaked into that variable, one tab-completion would destroy the
archive. So the write routes refuse while the read connection is set, and the console says on
every screen which database is on it.

These tests do not open a second database. They assert the wiring: which setting each route
reads, what refuses, and what the console is told. The connection itself is one
`create_async_engine` call with `default_transaction_read_only=on`, and a test that stood up a
second Postgres to prove SQLAlchemy connects would be testing SQLAlchemy.
"""

from __future__ import annotations

import uuid

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession

from factories import make_prompt, make_user
from helpers import auth_headers
from rascal.config import get_settings
from rascal.models import SocialAsset
from rascal.services import readonly_db

REMOTE = "postgresql://reader:secret@ep-cool-frog-12345.us-east-2.aws.neon.tech/rascal"
#: Refused instantly rather than resolved and timed out. The one test that touches a socket
#: should cost milliseconds, not a DNS lookup and six connection attempts.
UNREACHABLE = "postgresql://reader:secret@127.0.0.1:1/rascal"

#: Every write the console can make. A route added later and not listed here is a route that
#: will happily save to `localhost` while showing production — the failure this file is about.
CONSOLE_WRITES = [
    (
        "POST",
        "/v1/prompts",
        {
            "kind": "question",
            "cadence": "daily",
            "completion_mode": "text",
            "body": "A new one.",
            "theme": "humor",
        },
    ),
    ("PATCH", "/v1/prompts/{prompt}", {"theme": "humor"}),
    ("PUT", "/v1/prompts/{prompt}/active", {"active": False}),
    ("DELETE", "/v1/prompts/{prompt}/override", None),
    ("POST", "/v1/social/assets", {"headline": "hello"}),
    ("PATCH", "/v1/social/assets/{asset}", {"headline": "edited"}),
    ("POST", "/v1/social/assets/{asset}/render", {"provider": "openai_image", "kind": "image"}),
    (
        "POST",
        "/v1/prompts/candidates",
        {
            "candidates": [
                {
                    "kind": "question",
                    "body": "What did {they} say about it?",
                    "theme": "their-words",
                }
            ]
        },
    ),
    ("POST", "/v1/social/assets/{asset}/image", None),
    ("POST", "/v1/social/assets/{asset}/publish", {}),
    # A publication that does not exist: `LocalWrites` is a dependency, so the refusal happens
    # before the handler ever looks the row up. Using a real one would test the same thing and
    # need a fixture to build it.
    ("POST", "/v1/social/publications/{publication}/cancel", None),
]


@pytest.fixture
async def admin(session: AsyncSession):
    user = await make_user(session, display_name="Owner")
    user.is_admin = True
    await session.commit()
    return user


@pytest.fixture(autouse=True)
def _clean_engines():
    readonly_db.reset()
    yield
    readonly_db.reset()


def _reading(app, url: str = REMOTE):
    """Point the console elsewhere without touching `DATABASE_URL`.

    The override is on `get_settings`, so `DATABASE_URL` keeps its value throughout — which is
    the property under test as much as anything else here.
    """
    from rascal.config import get_settings as real

    app.dependency_overrides[real] = lambda: real().model_copy(
        update={"admin_read_database_url": url}
    )
    return real


# --- The URL somebody actually pastes -------------------------------------------------------


@pytest.mark.parametrize(
    "pasted",
    [
        "postgres://u:p@ep-x.neon.tech/rascal?sslmode=require",
        "postgresql://u:p@ep-x.neon.tech/rascal?sslmode=require",
        "postgresql+psycopg://u:p@ep-x.neon.tech/rascal?sslmode=require",
    ],
)
def test_every_shape_neon_hands_you_is_accepted(pasted: str) -> None:
    """Neon's console copies out `postgresql://`, and SQLAlchemy needs a driver.

    Without this the paste fails with a "can't load plugin" message naming neither the setting
    nor the fix, which is the worst possible first experience of a feature whose whole promise
    is "paste the string and look at production".
    """
    assert readonly_db.normalise(pasted).startswith("postgresql+psycopg://")
    assert readonly_db.describe(pasted) == "ep-x.neon.tech"


def test_the_host_is_reported_and_the_password_is_not() -> None:
    """The chip naming the database must not be the thing that leaks the credential."""
    described = readonly_db.describe(REMOTE)
    assert described == "ep-cool-frog-12345.us-east-2.aws.neon.tech"
    assert "secret" not in described


def test_the_connection_refuses_writes_at_the_server() -> None:
    """A read-only role is the belt; this is the braces, and it does not depend on the role.

    Every physical connection is issued `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY`,
    so Postgres rejects a write on it whatever the credential is permitted to do — including
    if a future handler is wired to the wrong session by mistake.

    Asserted as a registered listener rather than as a `connect_args` entry, which was the
    first attempt: that never appears in `create_connect_args`, so nothing could check it and
    a driver change could have dropped the guarantee in silence.
    """
    assert readonly_db.READ_ONLY_STATEMENT == "SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY"
    engine = readonly_db.get_engine(REMOTE)
    listeners = {getattr(fn, "__name__", "") for fn in engine.pool.dispatch.connect}
    assert "_read_only" in listeners, "nothing sets the connection read-only on connect"
    # Small pool: this is one browser tab, and Neon's connection budget is what the production
    # app is already competing for.
    assert engine.pool.size() <= 2


def test_the_engine_is_reused_rather_than_rebuilt_per_request() -> None:
    assert readonly_db.get_engine(REMOTE) is readonly_db.get_engine(REMOTE)


# --- Wiring ---------------------------------------------------------------------------------


async def test_by_default_the_console_reads_the_database_this_process_writes(
    client: AsyncClient, admin
) -> None:
    payload = (await client.get("/v1/admin/ops", headers=auth_headers(admin))).json()
    assert payload["database"]["reading"] == "local"
    assert payload["database"]["read_only"] is False
    # The host is named even in the ordinary case — a console that identifies its source only
    # when the source is unusual is one you have to remember to distrust.
    assert payload["database"]["host"]


def test_reading_elsewhere_is_announced_and_marked_read_only() -> None:
    """The block the console's chip is drawn from.

    A unit rather than a request, because the route that carries it also needs a live session
    and this suite does not open sockets. What the block *says* is the thing worth pinning.
    """
    from rascal.routers.admin import _database

    settings = get_settings().model_copy(update={"admin_read_database_url": REMOTE})
    block = _database(settings)
    assert block["reading"] == "remote"
    assert block["read_only"] is True
    assert block["host"] == "ep-cool-frog-12345.us-east-2.aws.neon.tech"
    assert "secret" not in str(block), "the chip leaks the password"
    assert "ADMIN_READ_DATABASE_URL" in str(block["note"])


@pytest.mark.parametrize(("method", "path", "body"), CONSOLE_WRITES)
async def test_every_console_write_refuses_while_reading_elsewhere(
    client: AsyncClient, session: AsyncSession, app, admin, method: str, path: str, body
) -> None:
    """Showing production and saving to localhost is worse than either on its own."""
    prompt = await make_prompt(session)
    asset = SocialAsset(headline="an existing draft", created_by_user_id=admin.id)
    session.add(asset)
    await session.commit()
    target = (
        path.replace("{prompt}", str(prompt.id))
        .replace("{asset}", str(asset.id))
        .replace("{publication}", str(uuid.uuid4()))
    )
    real = _reading(app)
    try:
        response = await client.request(method, target, json=body, headers=auth_headers(admin))
    finally:
        app.dependency_overrides.pop(real, None)
    assert response.status_code == 403, f"{method} {path} wrote while reading elsewhere"
    message = response.json()["error"]["message"]
    assert "ADMIN_READ_DATABASE_URL" in message
    # The refusal has to say how to get back to editing, or it is a wall rather than a door.
    assert "Unset" in message


#: Console POSTs that persist nothing — they ask a model a question and hand back the answer.
#: Listed rather than inferred, because "does this route write" is not visible from its path
#: and the sweep below has to be told the difference to be worth anything.
NON_PERSISTING = {
    ("POST", "/v1/social/chat"),
    ("POST", "/v1/social/concepts"),
    ("POST", "/v1/social/shot-list"),
    ("POST", "/v1/prompts/preview"),
    # Reads the library to build a style reference and asks a model for candidates. The
    # candidates come back in the response body; `POST /v1/prompts/candidates` above is the
    # one that writes any of them down.
    ("POST", "/v1/prompts/generate"),
}


def test_the_write_sweep_covers_every_console_write() -> None:
    """A console write added later and not listed above is the hole this file exists to close.

    Derived from the app's own `openapi()` rather than from a hand-kept list, the same way
    `test_admin.py` asserts its route sweep — so a new persisting route under `/v1/prompts` or
    `/v1/social` fails here until somebody decides whether it needs the guard.

    Read against the dependency tree first, which found nothing and passed: this FastAPI keeps
    an included router as a nested object with no walkable `routes`, so the walk compared an
    empty set to an empty set. A sweep that can silently assert nothing is worse than no sweep.
    """
    from rascal.main import create_app

    spec = create_app(get_settings()).openapi()["paths"]
    surface = {
        (method.upper(), path)
        for path, operations in spec.items()
        if path.startswith(("/v1/prompts", "/v1/social"))
        for method in operations
        if method.upper() in {"POST", "PATCH", "PUT", "DELETE"}
    }
    assert surface, "the sweep found no console routes — it is asserting nothing"

    listed = {
        (
            method,
            path.replace("{prompt}", "{prompt_id}")
            .replace("{asset}", "{asset_id}")
            .replace("{publication}", "{publication_id}"),
        )
        for method, path, _ in CONSOLE_WRITES
    }
    unaccounted = surface - listed - NON_PERSISTING
    assert not unaccounted, (
        "these console routes write but are not covered by the read-only guard sweep: "
        f"{sorted(unaccounted)} — add them to CONSOLE_WRITES with a LocalWrites dependency, "
        "or to NON_PERSISTING if they genuinely store nothing"
    )


async def test_an_unreachable_target_explains_itself_without_leaking_the_url(
    client: AsyncClient, app, admin
) -> None:
    """The likeliest failure is the first paste of a URL, so it gets the clearest message.

    Left to propagate, SQLAlchemy's `OperationalError` puts the host, the port, every resolved
    IP and the failing username into the response body — most of a connection string, rendered
    in a browser. This is the one test in the suite that touches the network, and it does so
    against a host that cannot exist.
    """
    real = _reading(app, UNREACHABLE)
    try:
        response = await client.get("/v1/admin/snapshot", headers=auth_headers(admin))
    finally:
        app.dependency_overrides.pop(real, None)

    assert response.status_code >= 400
    message = response.json()["error"]["message"]
    assert "ADMIN_READ_DATABASE_URL" in message
    assert "unset it" in message.lower(), "the error does not say how to get back"
    assert "secret" not in message, "the error leaks the password"
    assert "reader:" not in message


def test_database_url_is_never_read_from_the_console_setting() -> None:
    """The destructive make targets must not be able to see the console's target.

    `make reset-db` runs `alembic downgrade base` against `DATABASE_URL`. Nothing may make
    that variable resolve to the console's read target, so `DatabaseSettings` — which is all
    Alembic and the seed job construct — must not carry the field at all.
    """
    from rascal.config import DatabaseSettings

    assert "admin_read_database_url" not in DatabaseSettings.model_fields
    assert "admin_read_database_url" in get_settings().model_fields
