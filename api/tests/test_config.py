"""What each entry point is actually allowed to require.

The API needs its whole configuration surface and should refuse to start without it. A
migration needs a database and nothing else. Conflating the two is not a theoretical
problem: it took down the pre-flight migration against Neon, where the workflow supplies a
connection string and no S3 credentials, because Alembic resolved its URL through the full
`Settings` object and pydantic refused to build one.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from rascal.config import DatabaseSettings, Settings

DUMMY_URL = "postgresql+psycopg://user:pw@example.invalid/db"

# Required by the service, irrelevant to a connection. Derived from the models rather than
# listed, so adding a required setting cannot quietly make this test vacuous.
APP_ONLY_REQUIRED = {
    name
    for name, field in Settings.model_fields.items()
    if field.is_required() and name not in DatabaseSettings.model_fields
}


@pytest.fixture
def only_a_database_url(monkeypatch: pytest.MonkeyPatch) -> None:
    """An environment like the migration workflow's: a URL, and none of the app's secrets."""
    for name in APP_ONLY_REQUIRED:
        monkeypatch.delenv(name.upper(), raising=False)
        monkeypatch.delenv(name.lower(), raising=False)


def test_the_app_has_settings_a_connection_does_not_need() -> None:
    """If this set is ever empty the two tests below stop proving anything."""
    assert APP_ONLY_REQUIRED, "Settings and DatabaseSettings require the same fields"


def test_a_migration_needs_only_a_connection_string(only_a_database_url: None) -> None:
    settings = DatabaseSettings(_env_file=None, database_url=DUMMY_URL)
    assert settings.sync_database_url == DUMMY_URL


def test_direct_database_url_wins_for_migrations() -> None:
    direct = "postgresql+psycopg://user:pw@direct.example.invalid/db"
    settings = DatabaseSettings(_env_file=None, database_url=DUMMY_URL, direct_database_url=direct)
    assert settings.sync_database_url == direct


def test_the_app_still_refuses_to_start_half_configured(only_a_database_url: None) -> None:
    """Narrowing what Alembic needs must not narrow what the service demands of itself."""
    with pytest.raises(ValidationError) as raised:
        Settings(_env_file=None, database_url=DUMMY_URL)

    missing = {error["loc"][0] for error in raised.value.errors()}
    assert missing == APP_ONLY_REQUIRED
