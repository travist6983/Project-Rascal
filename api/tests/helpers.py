"""Small helpers shared by the HTTP tests."""

from __future__ import annotations

from rascal.config import get_settings
from rascal.models import User
from rascal.services.tokens import create_access_token


def auth_headers(user: User) -> dict[str, str]:
    """A bearer header for a user built directly through the ORM."""
    token, _ = create_access_token(user.id, get_settings())
    return {"Authorization": f"Bearer {token}"}
