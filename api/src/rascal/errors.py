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
    CONFLICT = "conflict"
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
    ErrorCode.CONFLICT: 409,
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
