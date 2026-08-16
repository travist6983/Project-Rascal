"""A local Google, so no test touches the network.

Deliberately a second keypair rather than a shared one with `apple_stub`. Two providers using
one signing key would make `test_an_apple_token_is_not_a_google_token` pass for the wrong
reason — the audiences would differ but the signature would verify, and the test would not be
telling you what it claims to.
"""

from __future__ import annotations

import datetime as dt
from typing import Any

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

from apple_stub import _b64

KEY_ID = "google-test-key"
CLIENT_ID = "1234567890-test.apps.googleusercontent.com"
SECOND_CLIENT_ID = "0987654321-web.apps.googleusercontent.com"


def generate_keypair() -> tuple[rsa.RSAPrivateKey, dict[str, Any]]:
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


def google_token(
    google_keypair: tuple[rsa.RSAPrivateKey, dict[str, Any]],
    *,
    subject: str = "104729000000000000001",
    audience: str | None = None,
    # `accounts.google.com` and `https://accounts.google.com` are both published as correct
    # and both are seen in the wild, which is why the verifier's `iss` check is a list.
    issuer: str = "https://accounts.google.com",
    email: str | None = "parent@gmail.com",
    email_verified: object = True,
    expires_in: int = 600,
    kid: str = KEY_ID,
    key: rsa.RSAPrivateKey | None = None,
) -> str:
    private, _ = google_keypair
    now = dt.datetime.now(tz=dt.UTC)
    claims = {
        "iss": issuer,
        "aud": audience or CLIENT_ID,
        "sub": subject,
        "iat": int(now.timestamp()),
        "exp": int((now + dt.timedelta(seconds=expires_in)).timestamp()),
        "email": email,
        "email_verified": email_verified,
    }
    return jwt.encode(claims, key or private, algorithm="RS256", headers={"kid": kid})
