"""A local Apple, so no test touches the network.

A generated RSA keypair, the JWKS document Apple would have served for it, and a signer that
mints identity tokens against it. The fixtures that wrap this live in `conftest.py`, so any
test module gets `apple_client` without importing it — importing a fixture and then naming it
as a parameter shadows it, which is a redefinition rather than a reuse.

Kept apart from `test_auth.py` because three phases need it: Apple sign-in, credential linking
(`test_credentials.py`), and the Google verifier that is built against the same shape.
"""

from __future__ import annotations

import base64
import datetime as dt
from typing import Any

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

KEY_ID = "rascal-test-key"


def _b64(value: int) -> str:
    raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def generate_keypair() -> tuple[rsa.RSAPrivateKey, dict[str, Any]]:
    """A private key plus the JWKS Apple would publish for it."""
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    numbers = private.public_key().public_numbers()
    jwks = {
        "keys": [
            {
                "kty": "RSA",
                "kid": KEY_ID,
                "use": "sig",
                "alg": "RS256",
                "n": _b64(numbers.n),
                "e": _b64(numbers.e),
            }
        ]
    }
    return private, jwks


def apple_token(
    apple_keypair: tuple[rsa.RSAPrivateKey, dict[str, Any]],
    *,
    subject: str = "001.abcdef",
    audience: str | None = None,
    issuer: str = "https://appleid.apple.com",
    email: str | None = "relay@privaterelay.appleid.com",
    expires_in: int = 600,
    kid: str = KEY_ID,
) -> str:
    # Imported here rather than at module scope: `conftest.py` installs the test database URL
    # as an import side effect, and reading settings above it would cache the wrong one.
    from rascal.config import get_settings

    private, _ = apple_keypair
    now = dt.datetime.now(tz=dt.UTC)
    claims = {
        "iss": issuer,
        # `apple_bundle_id` is a list of audiences (phase 51). A real Apple token carries one
        # string here, so the default token does too — the list-valued case is exercised
        # deliberately in `test_auth.py`, not smuggled in as every test's default.
        "aud": audience or get_settings().apple_bundle_id[0],
        "sub": subject,
        "iat": int(now.timestamp()),
        "exp": int((now + dt.timedelta(seconds=expires_in)).timestamp()),
        "email": email,
        "email_verified": "true",
    }
    return jwt.encode(claims, private, algorithm="RS256", headers={"kid": kid})
