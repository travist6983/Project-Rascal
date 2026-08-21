"""The one error shape this API emits, and the one handler that renders it.

    {"error": {"code": "not_authorized", "message": "...", "field": null}}

Clients switch on ``code``, never on message text. Adding a code is a deliberate act: it
goes in :class:`ErrorCode` and nowhere else. A stack trace or a psycopg message reaching a
client is a leak, not a debugging aid.
"""

from __future__ import annotations

import logging
from enum import StrEnum

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import SQLAlchemyError
from starlette.exceptions import HTTPException as StarletteHTTPException

log = logging.getLogger("rascal.errors")


class ErrorCode(StrEnum):
    """Stable machine-readable codes. The table in docs/api-contract.md is the contract."""

    UNAUTHENTICATED = "unauthenticated"
    TOKEN_EXPIRED = "token_expired"
    REFRESH_TOKEN_REUSED = "refresh_token_reused"
    NOT_AUTHORIZED = "not_authorized"
    NOT_FOUND = "not_found"
    VALIDATION_FAILED = "validation_failed"
    INVALID_DISPLAY_NAME = "invalid_display_name"
    ASSIGNMENT_EXPIRED = "assignment_expired"
    UPLOAD_INCOMPLETE = "upload_incomplete"
    # This provider subject already belongs to a different account. Never merged and never
    # reassigned — two archives with one credential between them is not a state this product
    # has an answer for.
    CREDENTIAL_IN_USE = "credential_in_use"
    # Refusing to revoke the only way left into an account. Distinct from `conflict` because a
    # client shows it as a sentence next to the button, not as an error.
    LAST_CREDENTIAL = "last_credential"
    CONFLICT = "conflict"
    # The household is on the free tier and the action needs a subscription. Distinct from
    # `not_authorized` because it is not a permission problem — the caller may do this, they
    # simply have not bought it yet, and a client shows it as a door rather than a wall.
    SUBSCRIPTION_REQUIRED = "subscription_required"
    # Unauthenticated endpoints only. See `services/rate_limit.py` and CLAUDE.md.
    RATE_LIMITED = "rate_limited"
    # A magic link that was already used, or has expired. Distinct from `unauthenticated`
    # because a client shows it as "this link is no longer good, here is how to get another"
    # rather than as a failed sign-in.
    SIGN_IN_LINK_INVALID = "sign_in_link_invalid"
    # The console asked to publish and the platform refused, or the service is not configured
    # to reach it. Distinct from `internal_error` because the cause is almost always outside
    # this service — an expired token, an image Meta could not fetch, a limit on their side —
    # and the console shows the platform's own words next to the button rather than "something
    # went wrong". Never carries a raw provider payload; `services/social/instagram.py`
    # reduces it to one sentence first.
    PUBLISH_FAILED = "publish_failed"
    INTERNAL_ERROR = "internal_error"


_STATUS_BY_CODE: dict[ErrorCode, int] = {
    ErrorCode.UNAUTHENTICATED: 401,
    ErrorCode.TOKEN_EXPIRED: 401,
    ErrorCode.REFRESH_TOKEN_REUSED: 401,
    ErrorCode.NOT_AUTHORIZED: 403,
    ErrorCode.NOT_FOUND: 404,
    ErrorCode.VALIDATION_FAILED: 422,
    # 400 rather than 422: the body parsed and the field is the right type, the value is
    # just not a name. A client shows this one next to the text field it came from.
    ErrorCode.INVALID_DISPLAY_NAME: 400,
    ErrorCode.ASSIGNMENT_EXPIRED: 409,
    ErrorCode.UPLOAD_INCOMPLETE: 409,
    ErrorCode.CREDENTIAL_IN_USE: 409,
    ErrorCode.LAST_CREDENTIAL: 409,
    ErrorCode.CONFLICT: 409,
    ErrorCode.SUBSCRIPTION_REQUIRED: 402,
    ErrorCode.RATE_LIMITED: 429,
    ErrorCode.SIGN_IN_LINK_INVALID: 401,
    # 502 rather than 500: this service worked and the thing it called did not.
    ErrorCode.PUBLISH_FAILED: 502,
    ErrorCode.INTERNAL_ERROR: 500,
}


class RascalError(Exception):
    """Every deliberate failure in this service. The status follows from the code."""

    def __init__(
        self,
        code: ErrorCode,
        message: str,
        *,
        field: str | None = None,
        status_code: int | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.field = field
        self.status_code = status_code or _STATUS_BY_CODE[code]


def not_found(what: str) -> RascalError:
    return RascalError(ErrorCode.NOT_FOUND, f"{what} not found")


def not_authorized(message: str = "You do not have access to this child.") -> RascalError:
    return RascalError(ErrorCode.NOT_AUTHORIZED, message)


def validation_failed(message: str, field: str | None = None) -> RascalError:
    return RascalError(ErrorCode.VALIDATION_FAILED, message, field=field)


def error_body(code: ErrorCode, message: str, field: str | None) -> dict[str, object]:
    return {"error": {"code": str(code), "message": message, "field": field}}


def _render(exc: RascalError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content=error_body(exc.code, exc.message, exc.field),
    )


def _first_field(exc: RequestValidationError) -> str | None:
    """Pydantic locations look like ("body", "occurred_at"); clients want "occurred_at"."""
    for err in exc.errors():
        location = [str(part) for part in err.get("loc", ()) if part not in ("body", "query")]
        if location:
            return ".".join(location)
    return None


def register_error_handlers(app: FastAPI) -> None:
    """Wire every failure mode onto the single error shape."""

    @app.exception_handler(RascalError)
    async def _rascal(_: Request, exc: RascalError) -> JSONResponse:
        return _render(exc)

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, exc: RequestValidationError) -> JSONResponse:
        first = exc.errors()[0]["msg"] if exc.errors() else "Request validation failed."
        return _render(RascalError(ErrorCode.VALIDATION_FAILED, first, field=_first_field(exc)))

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        # Starlette raises these for unrouted paths and bad methods before we ever run.
        code = {
            401: ErrorCode.UNAUTHENTICATED,
            403: ErrorCode.NOT_AUTHORIZED,
            404: ErrorCode.NOT_FOUND,
            409: ErrorCode.CONFLICT,
            422: ErrorCode.VALIDATION_FAILED,
        }.get(exc.status_code, ErrorCode.INTERNAL_ERROR)
        message = exc.detail if isinstance(exc.detail, str) else "Request failed."
        return _render(RascalError(code, message, status_code=exc.status_code))

    @app.exception_handler(SQLAlchemyError)
    async def _database(_: Request, exc: SQLAlchemyError) -> JSONResponse:
        log.exception("database error", exc_info=exc)
        return _render(RascalError(ErrorCode.INTERNAL_ERROR, "A database error occurred."))

    @app.exception_handler(Exception)
    async def _unhandled(_: Request, exc: Exception) -> JSONResponse:
        log.exception("unhandled error", exc_info=exc)
        return _render(RascalError(ErrorCode.INTERNAL_ERROR, "An internal error occurred."))
