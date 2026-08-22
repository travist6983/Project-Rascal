"""A local Apple, for App Store Server Notifications V2.

**Nothing here has ever talked to Apple**, and the point of building it this thoroughly is
that the code under test cannot tell the difference. The chain these helpers mint has the
shape Apple's real one has and that Apple's own verifier insists on:

* exactly three certificates — leaf, intermediate, root;
* ECDSA throughout, with a **P-256 leaf**, because the library refuses any `alg` but `ES256`;
* the marker OIDs, which are the part a naive stub omits: the leaf must carry
  `1.2.840.113635.100.6.11.1` and the intermediate `1.2.840.113635.100.6.2.1`. Without them a
  certificate that chains to an Apple root is still refused, and a stub without them cannot
  tell you whether your verification works;
* validity dates checked against the payload's **own `signedDate`**, not against now — which
  is what makes `expired_leaf` a test rather than a race.

`sign_notification` builds the nested shape that implementations get wrong:
`data.signedTransactionInfo` and `data.signedRenewalInfo` are **their own JWS strings**, not
objects, and each is signed by the same leaf.
"""

from __future__ import annotations

import base64
import datetime as dt
import uuid
from dataclasses import dataclass

import jwt
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

LEAF_MARKER_OID = "1.2.840.113635.100.6.11.1"
INTERMEDIATE_MARKER_OID = "1.2.840.113635.100.6.2.1"

BUNDLE_ID = "com.travisterry.childarchive"
APP_APPLE_ID = 1234567890
ANNUAL_PRODUCT_ID = "com.travisterry.childarchive.subscription.annual"
# The other half of D5a's subscription group, added by phase 113 so a test can tell the two
# cadences apart on the wire. One group holding both durations is what makes a monthly→annual
# move a *plan change* rather than two live subscriptions — see `docs/decisions.md` D5a.
MONTHLY_PRODUCT_ID = "com.travisterry.childarchive.subscription.monthly"
# An identifier that is real enough to sign and deliberately absent from `constants.PRODUCT_PLANS`
# — a future non-renewing product, or one nobody has decided on yet. It must read as `plan: null`
# rather than being guessed at by substring.
UNKNOWN_PRODUCT_ID = "com.travisterry.childarchive.book.hardcover"

# Fixed so a test never depends on the wall clock. Every certificate below is valid across
# this window and every payload is signed inside it.
_NOT_BEFORE = dt.datetime(2026, 1, 1, tzinfo=dt.UTC)
# future-date: a certificate's notAfter is a future date by construction. This one is the
# *valid* chain, so it has to outlast the suite; `build_chain(leaf_not_after=...)` is how a
# test asks for an expired one, and that value is derived from a past `signedDate`.
_NOT_AFTER = dt.datetime(2030, 1, 1, tzinfo=dt.UTC)  # future-date: a notAfter, by construction


@dataclass(frozen=True)
class Chain:
    """A minted chain: the root to trust, and the leaf that signs payloads."""

    root_der: bytes
    intermediate_der: bytes
    leaf_der: bytes
    leaf_key: ec.EllipticCurvePrivateKey

    @property
    def x5c(self) -> list[str]:
        """The `x5c` header, base64 DER, leaf first — the order Apple sends and the
        verifier's `certificates[0]` assumes."""
        return [
            base64.b64encode(der).decode()
            for der in (self.leaf_der, self.intermediate_der, self.root_der)
        ]


def _name(common_name: str) -> x509.Name:
    return x509.Name(
        [
            x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Rascal Test Authority"),
            x509.NameAttribute(NameOID.COMMON_NAME, common_name),
        ]
    )


def _marker(oid: str) -> x509.UnrecognizedExtension:
    """An Apple marker extension. The value is an ASN.1 NULL; only presence is checked."""
    return x509.UnrecognizedExtension(x509.ObjectIdentifier(oid), b"\x05\x00")


def build_chain(
    *,
    leaf_not_after: dt.datetime | None = None,
    root_common_name: str = "Rascal Test Root CA - G3",
) -> Chain:
    """Mint root -> intermediate -> leaf.

    `leaf_not_after` in the past relative to a payload's `signedDate` is how the expired-leaf
    test is written. `root_common_name` differing is not what makes an untrusted chain
    untrusted — *not being in the trust store* is — and the untrusted-root test works by
    building a whole second chain and trusting only the first.
    """
    root_key = ec.generate_private_key(ec.SECP384R1())
    intermediate_key = ec.generate_private_key(ec.SECP384R1())
    # P-256: ES256 is the only algorithm the verifier accepts, and it means this curve.
    leaf_key = ec.generate_private_key(ec.SECP256R1())

    root_name = _name(root_common_name)
    root = (
        x509.CertificateBuilder()
        .subject_name(root_name)
        .issuer_name(root_name)
        .public_key(root_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(_NOT_BEFORE)
        .not_valid_after(_NOT_AFTER)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=False,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.SubjectKeyIdentifier.from_public_key(root_key.public_key()), critical=False
        )
        .sign(root_key, hashes.SHA384())
    )

    intermediate_name = _name("Rascal Test Intermediate")
    intermediate = (
        x509.CertificateBuilder()
        .subject_name(intermediate_name)
        .issuer_name(root_name)
        .public_key(intermediate_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(_NOT_BEFORE)
        .not_valid_after(_NOT_AFTER)
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=False,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.SubjectKeyIdentifier.from_public_key(intermediate_key.public_key()),
            critical=False,
        )
        .add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_public_key(root_key.public_key()),
            critical=False,
        )
        # The marker Apple's verifier requires on the intermediate.
        .add_extension(_marker(INTERMEDIATE_MARKER_OID), critical=False)
        .sign(root_key, hashes.SHA384())
    )

    leaf = (
        x509.CertificateBuilder()
        .subject_name(_name("Rascal Test Leaf"))
        .issuer_name(intermediate_name)
        .public_key(leaf_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(_NOT_BEFORE)
        .not_valid_after(leaf_not_after or _NOT_AFTER)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.SubjectKeyIdentifier.from_public_key(leaf_key.public_key()), critical=False
        )
        .add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_public_key(intermediate_key.public_key()),
            critical=False,
        )
        # The marker Apple's verifier requires on the leaf.
        .add_extension(_marker(LEAF_MARKER_OID), critical=False)
        .sign(intermediate_key, hashes.SHA384())
    )

    return Chain(
        root_der=root.public_bytes(serialization.Encoding.DER),
        intermediate_der=intermediate.public_bytes(serialization.Encoding.DER),
        leaf_der=leaf.public_bytes(serialization.Encoding.DER),
        leaf_key=leaf_key,
    )


def _sign(chain: Chain, claims: dict) -> str:
    """One JWS, ES256, carrying the chain in `x5c`. The only signer in this module."""
    return jwt.encode(
        claims,
        chain.leaf_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        ),
        algorithm="ES256",
        headers={"x5c": chain.x5c},
    )


def millis(moment: dt.datetime) -> int:
    """Apple's timestamps are milliseconds since the epoch, never seconds."""
    return int(moment.timestamp() * 1000)


def sign_notification(
    chain: Chain,
    *,
    notification_type: str,
    subtype: str | None = None,
    signed_date: dt.datetime,
    environment: str = "Production",
    original_transaction_id: str = "2000000000000001",
    product_id: str = ANNUAL_PRODUCT_ID,
    app_account_token: uuid.UUID | str | None = None,
    expires_date: dt.datetime | None = None,
    bundle_id: str = BUNDLE_ID,
    app_apple_id: int | None = APP_APPLE_ID,
    include_transaction_info: bool = True,
    include_renewal_info: bool = True,
) -> str:
    """A whole V2 notification, nested exactly as Apple nests one.

    **`signedTransactionInfo` and `signedRenewalInfo` are JWS strings, not objects.** That is
    the shape the real thing has, and building the stub any other way would let a
    "simplification" of the decoder pass its tests.
    """
    transaction_claims = {
        "originalTransactionId": original_transaction_id,
        "transactionId": original_transaction_id,
        "bundleId": bundle_id,
        "productId": product_id,
        "environment": environment,
        "type": "Auto-Renewable Subscription",
        "signedDate": millis(signed_date),
        "purchaseDate": millis(signed_date),
        "originalPurchaseDate": millis(signed_date),
        "quantity": 1,
        "inAppOwnershipType": "PURCHASED",
    }
    if app_account_token is not None:
        transaction_claims["appAccountToken"] = str(app_account_token)
    if expires_date is not None:
        transaction_claims["expiresDate"] = millis(expires_date)

    renewal_claims = {
        "originalTransactionId": original_transaction_id,
        "autoRenewProductId": product_id,
        "productId": product_id,
        "autoRenewStatus": 1,
        "environment": environment,
        "signedDate": millis(signed_date),
        "recentSubscriptionStartDate": millis(signed_date),
    }

    data: dict = {
        "bundleId": bundle_id,
        "environment": environment,
        "bundleVersion": "1",
    }
    if app_apple_id is not None:
        data["appAppleId"] = app_apple_id
    if include_transaction_info:
        data["signedTransactionInfo"] = _sign(chain, transaction_claims)
    if include_renewal_info:
        data["signedRenewalInfo"] = _sign(chain, renewal_claims)

    payload: dict = {
        "notificationType": notification_type,
        "notificationUUID": str(uuid.uuid4()),
        "version": "2.0",
        "signedDate": millis(signed_date),
        "data": data,
    }
    if subtype is not None:
        payload["subtype"] = subtype
    return _sign(chain, payload)


def tamper(signed_payload: str) -> str:
    """Flip one character of the payload segment, leaving the signature intact.

    A tampered payload rather than a tampered signature, because that is the interesting
    direction: the signature is still Apple's, and only a verifier that actually checks it
    against the body notices.
    """
    header, body, signature = signed_payload.split(".")
    flipped = "B" if body[10] != "B" else "C"
    return f"{header}.{body[:10]}{flipped}{body[11:]}.{signature}"
