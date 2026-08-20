"""Verifying and decoding an App Store Server Notification V2.

**This module does the verifying and nothing else.** What a verified notification *does* to a
household is `services/app_store_events.py`, and the split is not tidiness: it is what makes
"can a notification write `tier` without a verified signature" a question you can answer by
reading one file. The router calls :func:`verify_notification` first and only reaches the
writer with its return value, so an unverifiable payload has no path to the writer at all.

Verification is delegated to Apple's own `app-store-server-library`, which is the only
dependency phase 37a adds. Hand-rolling `x5c` chain verification is exactly the sort of clever
this project has a standing rule against, and getting it subtly wrong means a stranger writes
entitlements. What the library checks, and what we would have had to get right:

* the chain is exactly three certificates and terminates at a bundled Apple root;
* the leaf carries OID `1.2.840.113635.100.6.11.1` and the intermediate
  `1.2.840.113635.100.6.2.1`, so an unrelated certificate under an Apple root is still refused;
* certificate validity dates, against the payload's own `signedDate`;
* the leaf's key actually signs the payload;
* `bundleId` matches this app, and in Production `appAppleId` does too.

**Online checks are off.** OCSP would put a synchronous `requests.post` to Apple on the event
loop inside every webhook, and a slow revocation responder would turn into Apple retrying us.

**Both environments get a real verifier, and that is not a weakening.** Apple's library pins a
verifier to one environment and raises `INVALID_ENVIRONMENT` for the other, so accepting a
Sandbox notification at all requires a second verifier. Both perform identical cryptography;
the only difference is which `environment` claim they accept. Deciding a Sandbox notification
may not *write* anything in production is a separate judgement and belongs to the writer,
which is where `docs/api-contract.md` and the reader both expect to find it.
"""

from __future__ import annotations

import datetime as dt
import logging
import uuid
from dataclasses import dataclass
from pathlib import Path

import jwt
from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.signed_data_verifier import (
    SignedDataVerifier,
    VerificationException,
)

from rascal.config import Settings
from rascal.constants import AppStoreEnvironment

log = logging.getLogger("rascal.app_store")

#: Where the bundled trust anchors live. See the README in that directory — it is empty in the
#: repository, and the endpoint fails closed until it is not.
CERTS_DIR = Path(__file__).resolve().parent.parent / "certs" / "appstore"


class NotificationUnverifiable(Exception):
    """The payload did not verify. The router renders this as `401` and nothing else.

    A distinct type rather than `RascalError` because the only correct handling is one
    `except` in one router: catching this anywhere else would be catching the security
    control.
    """


@dataclass(frozen=True)
class VerifiedNotification:
    """One notification, verified and fully decoded — every JWS unwrapped.

    Frozen because the writer takes decisions off this and a mutable payload passed through
    three guards is a payload that can be different at the third one.
    """

    notification_type: str
    subtype: str | None
    #: Apple's `signedDate` off the **outer** payload, in UTC. The ordering key.
    signed_date: dt.datetime
    environment: AppStoreEnvironment
    original_transaction_id: str | None
    product_id: str | None
    expires_date: dt.datetime | None
    #: `appAccountToken` parsed as a UUID, or `None` when absent or malformed. **Never
    #: raises** — a client that sent a bad token produces an orphan receipt, not a 500.
    app_account_token: uuid.UUID | None
    #: The whole decode, nested JWSs replaced by their decoded objects, for `raw_payload`.
    raw: dict


def load_root_certificates(directory: Path) -> list[bytes]:
    """Every DER `.cer` in *directory*, sorted so the list is stable across filesystems.

    An empty list is returned rather than raised on, so the caller decides what to do about
    it — and every caller here decides to refuse. Apple's chain verifier also treats an empty
    trust store as `INVALID_CERTIFICATE`, so this fails closed twice over.
    """
    if not directory.is_dir():
        return []
    return [path.read_bytes() for path in sorted(directory.glob("*.cer"))]


class AppStoreVerifier:
    """Holds one verifier per environment, built once per process.

    Built eagerly at construction so a misconfiguration is an `ERROR` in the startup logs
    rather than a 401 nobody can explain. A verifier that could not be built stays `None` and
    every payload for that environment is refused.
    """

    def __init__(self, settings: Settings, *, certs_dir: Path | None = None) -> None:
        self._roots = load_root_certificates(
            certs_dir or settings.app_store_root_certs_dir or CERTS_DIR
        )
        self._bundle_id = settings.resolved_app_store_bundle_id
        self._app_apple_id = settings.app_store_app_apple_id
        self._verifiers: dict[Environment, SignedDataVerifier] = {}

        if not self._roots:
            log.error(
                "no App Store trust anchors: every notification will be refused with 401",
                extra={"certs_dir": str(certs_dir or CERTS_DIR)},
            )
            return

        if self._bundle_id is None:
            # `APPLE_BUNDLE_ID` names more than one audience and `APP_STORE_BUNDLE_ID` is
            # unset, so there is nothing to pin a payload to. Refusing everything is the only
            # safe answer: guessing would accept notifications about a different app.
            log.error(
                "APP_STORE_BUNDLE_ID is unset and APPLE_BUNDLE_ID names more than one "
                "audience, so every notification will be refused with 401. A signed payload "
                "is pinned to one bundle id and it cannot be guessed from a list.",
                extra={"apple_bundle_id": settings.apple_bundle_id},
            )
            return

        for environment in (Environment.SANDBOX, Environment.PRODUCTION):
            try:
                self._verifiers[environment] = SignedDataVerifier(
                    root_certificates=self._roots,
                    enable_online_checks=False,
                    environment=environment,
                    bundle_id=self._bundle_id,
                    app_apple_id=self._app_apple_id,
                )
            except ValueError:
                # Production without `app_store_app_apple_id`. Apple's library refuses to
                # build it, and so do we — a Production verifier that did not pin the app
                # would accept a signed notification about somebody else's app.
                log.error(
                    "APP_STORE_APP_APPLE_ID is unset, so Production notifications will be "
                    "refused with 401. See docs/blocked.md section 10.",
                    extra={"environment": environment.value},
                )

    @property
    def configured(self) -> bool:
        """Whether any payload at all can verify. False means the endpoint always 401s."""
        return bool(self._verifiers)

    def verify(self, signed_payload: str) -> VerifiedNotification:
        """Verify a `signedPayload` and decode it, nested JWSs and all.

        **Every failure is `NotificationUnverifiable`.** There is no branch that returns a
        partially-verified notification, and none that falls back to reading the payload
        unverified in order to log something useful about it.
        """
        if not self._verifiers:
            raise NotificationUnverifiable("No App Store trust anchors are configured.")

        # Production first, so the common case does one verification. A Sandbox payload fails
        # the Production verifier on the `environment` claim *after* its signature and chain
        # have already been checked — trying the second verifier re-checks the same
        # cryptography against the same roots, so this is a claim mismatch, not a retry past
        # a signature failure.
        payload = None
        last_error: VerificationException | None = None
        for environment in (Environment.PRODUCTION, Environment.SANDBOX):
            verifier = self._verifiers.get(environment)
            if verifier is None:
                continue
            try:
                payload = verifier.verify_and_decode_notification(signed_payload)
                break
            except VerificationException as exc:
                last_error = exc
            except Exception as exc:  # malformed JWS, bad base64, unparseable JSON
                raise NotificationUnverifiable(f"Payload could not be decoded: {exc}") from exc

        if payload is None:
            status = last_error.status.name if last_error else "VERIFICATION_FAILURE"
            raise NotificationUnverifiable(f"Payload did not verify: {status}")

        return self._decode(payload, environment, signed_payload)

    def _decode(
        self, payload: object, environment: Environment, signed_payload: str
    ) -> VerifiedNotification:
        """Unwrap the nested JWSs and flatten what the writer needs.

        **`data.signedTransactionInfo` and `data.signedRenewalInfo` are themselves JWS
        strings.** Reading `data.transactionInfo` as an object is the documented way to get
        this wrong: it yields `None`, writes nothing, and does so silently forever. They are
        verified with the same verifier rather than merely base64-decoded, because a payload
        whose outer signature is Apple's and whose inner transaction is not is precisely the
        shape of a forged upgrade.
        """
        verifier = self._verifiers[environment]
        data = getattr(payload, "data", None)

        transaction = None
        renewal = None
        # **The nested verifications raise the library's exception, not ours**, and an
        # uncaught one leaves this method as a `VerificationException` that the router does
        # not catch — a 500 where the answer is 401. That is not hypothetical: an outer
        # envelope Apple signed carrying an inner transaction Apple did not is exactly the
        # shape of a forged upgrade, and it is the payload that takes this path.
        try:
            if data is not None:
                signed_transaction = getattr(data, "signedTransactionInfo", None)
                if signed_transaction:
                    transaction = verifier.verify_and_decode_signed_transaction(signed_transaction)
                signed_renewal = getattr(data, "signedRenewalInfo", None)
                if signed_renewal:
                    renewal = verifier.verify_and_decode_renewal_info(signed_renewal)
        except VerificationException as exc:
            raise NotificationUnverifiable(
                f"A nested payload did not verify: {exc.status.name}"
            ) from exc

        signed_date = _moment(getattr(payload, "signedDate", None))
        if signed_date is None:
            # Without it there is no ordering key, and a row with a guessed one would make a
            # late retry look current. Refusing is the only safe answer.
            raise NotificationUnverifiable("Payload carries no signedDate.")

        original_transaction_id = _first_str(
            getattr(transaction, "originalTransactionId", None),
            getattr(data, "originalTransactionId", None) if data else None,
            getattr(renewal, "originalTransactionId", None),
        )

        # **The type and subtype are read from the verified claims, not from the model.**
        # Apple's library maps `notificationType` onto an enum and leaves it `None` for any
        # value it does not know — so a type Apple ships next year would arrive here as an
        # empty string, be recorded as one, and make the "unknown types are recorded and
        # acknowledged" rule quietly false. `record` is the already-verified payload's own
        # JSON, so this is the string Apple actually sent.
        record = _audit_record(signed_payload, environment)

        return VerifiedNotification(
            notification_type=str(record.get("notificationType") or ""),
            subtype=_optional_str(record.get("subtype")),
            signed_date=signed_date,
            environment="Sandbox" if environment == Environment.SANDBOX else "Production",
            original_transaction_id=original_transaction_id,
            product_id=_first_str(getattr(transaction, "productId", None)),
            expires_date=_moment(getattr(transaction, "expiresDate", None)),
            app_account_token=_as_uuid(getattr(transaction, "appAccountToken", None)),
            raw=record,
        )


def _optional_str(value: object) -> str | None:
    """A present, non-empty claim as a string; `None` for absent or blank.

    Apple omits `subtype` entirely rather than sending null, and an empty string would make
    `subtype == "GRACE_PERIOD"` comparisons read as "has no subtype" incorrectly.
    """
    return str(value) if value else None


def _enum_value(value: object) -> str | None:
    """Apple's library returns enums for known values and raw strings for unknown ones.

    Both have to survive: an unrecognised `notificationType` is recorded and acknowledged per
    the contract, so a decode that only understood the enum members would turn every new
    Apple notification type into a crash the first time Apple shipped one.
    """
    if value is None:
        return None
    raw = getattr(value, "value", value)
    return str(raw) if raw is not None else None


def _first_str(*values: object) -> str | None:
    for value in values:
        if value:
            return str(value)
    return None


def _moment(value: object) -> dt.datetime | None:
    """Apple's timestamps are **milliseconds** since the epoch, and always UTC here."""
    if value is None:
        return None
    if isinstance(value, dt.datetime):
        return value if value.tzinfo else value.replace(tzinfo=dt.UTC)
    try:
        return dt.datetime.fromtimestamp(int(value) / 1000, tz=dt.UTC)
    except (TypeError, ValueError, OSError, OverflowError):
        return None


def _as_uuid(value: object) -> uuid.UUID | None:
    """`appAccountToken` as a UUID, or `None`.

    **A malformed value is a null `family_id`, never an exception.** The client controls this
    string; a 500 here would let a bad build make Apple retry a notification forever.
    """
    if value is None:
        return None
    try:
        return uuid.UUID(str(value))
    except (ValueError, AttributeError, TypeError):
        log.warning("appAccountToken is not a UUID; recording an orphan receipt")
        return None


def _claims(signed: str) -> dict:
    """The claims of an **already-verified** JWS, as the plain JSON Apple actually sent.

    **This verifies nothing and must never be the only thing that touches a payload.** It is
    called exclusively on strings :meth:`AppStoreVerifier.verify` has already put through
    Apple's verifier, and only to build the audit record — every field this service *acts on*
    comes off the verified model objects instead.

    Re-decoding rather than re-serialising Apple's model objects is deliberate: those are
    slotted `attrs` classes whose mapping back to JSON is lossy and would silently drop any
    field Apple adds later. The point of `raw_payload` is that whoever opens it during an
    incident sees what Apple sent, not what our model of Apple could represent.
    """
    return jwt.decode(signed, options={"verify_signature": False})


def _audit_record(signed_payload: str, environment: Environment) -> dict:
    """The whole notification as JSON, every nested JWS replaced by its own claims.

    This is what lands in `app_store_transactions.raw_payload`.
    """
    record = _claims(signed_payload)
    record["environment"] = "Sandbox" if environment == Environment.SANDBOX else "Production"
    data = record.get("data")
    if isinstance(data, dict):
        for signed_key, decoded_key in (
            ("signedTransactionInfo", "transactionInfo"),
            ("signedRenewalInfo", "renewalInfo"),
        ):
            signed = data.pop(signed_key, None)
            if signed:
                data[decoded_key] = _claims(signed)
    return record
