"""Authentication and authorization dependencies.

Authorization lives here and only here. Every child-scoped route — whether it names the
child directly or reaches it through an entry, a media row, or an assignment — resolves the
owning child and runs :func:`require_child_access`. Retrofitting this across twenty
endpoints is how a hole gets left in one of them.

Failure is 403 `not_authorized`, never 404. Leaking existence is fine here, and a wrong 404
sends you debugging the wrong thing.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable, Coroutine
from dataclasses import dataclass
from typing import Annotated, Any

from fastapi import Depends, Path, Query, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from rascal.config import Settings, get_settings
from rascal.constants import GuardianRole
from rascal.db import get_session
from rascal.errors import ErrorCode, RascalError, not_authorized, not_found
from rascal.models import Assignment, Child, Entry, Guardian, Media, User
from rascal.services.apple import AppleVerifier
from rascal.services.tokens import decode_access_token

# auto_error=False so a missing header comes back in the standard error shape rather than
# Starlette's default {"detail": ...}.
bearer_scheme = HTTPBearer(auto_error=False, description="Access token from /v1/auth/*")

SettingsDep = Annotated[Settings, Depends(get_settings)]
SessionDep = Annotated[AsyncSession, Depends(get_session)]


# One verifier per process, so the JWKS cache is shared across every login.
_apple_verifier: AppleVerifier | None = None


def get_apple_verifier(settings: SettingsDep) -> AppleVerifier:
    global _apple_verifier
    if _apple_verifier is None:
        _apple_verifier = AppleVerifier(settings)
    return _apple_verifier


async def current_user(
    session: SessionDep,
    settings: SettingsDep,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)] = None,
) -> User:
    """The user behind the bearer token. 401 on anything else."""
    if credentials is None or not credentials.credentials:
        raise RascalError(ErrorCode.UNAUTHENTICATED, "An access token is required.")

    user_id = decode_access_token(credentials.credentials, settings)
    user = await session.get(User, user_id)
    if user is None:
        # The token verifies but the user is gone. Treat it as unauthenticated, not 404.
        raise RascalError(ErrorCode.UNAUTHENTICATED, "This account no longer exists.")
    return user


CurrentUser = Annotated[User, Depends(current_user)]


@dataclass(frozen=True)
class ChildAccess:
    """The resolved child, the caller, and the role that let them through."""

    child: Child
    user: User
    role: GuardianRole

    @property
    def child_id(self) -> uuid.UUID:
        return self.child.id

    @property
    def can_write(self) -> bool:
        return self.role == "parent"


async def require_child_access(
    session: AsyncSession,
    user: User,
    child_id: uuid.UUID,
    required_role: GuardianRole,
) -> ChildAccess:
    """The one authorization check. `parent` reads and writes; `viewer` reads only."""
    guardian = await session.scalar(
        select(Guardian).where(
            Guardian.user_id == user.id,
            Guardian.child_id == child_id,
            Guardian.revoked_at.is_(None),
        )
    )
    if guardian is None:
        raise not_authorized()
    if required_role == "parent" and guardian.role != "parent":
        raise not_authorized("This child is shared with you read-only.")

    child = await session.get(Child, child_id)
    if child is None:
        # A guardian row pointing at a missing child would be a data bug, not a permission
        # problem, so this one really is a 404.
        raise not_found("Child")
    return ChildAccess(child=child, user=user, role=guardian.role)


ChildAccessDependency = Callable[..., Coroutine[Any, Any, ChildAccess]]


def child_access(required_role: GuardianRole = "viewer") -> ChildAccessDependency:
    """For routes with `{child_id}` in the path."""

    async def dependency(
        session: SessionDep,
        user: CurrentUser,
        child_id: Annotated[uuid.UUID, Path()],
    ) -> ChildAccess:
        return await require_child_access(session, user, child_id, required_role)

    return dependency


def child_access_from_query(required_role: GuardianRole = "viewer") -> ChildAccessDependency:
    """For routes that name the child in the query string, like `GET /entries`."""

    async def dependency(
        session: SessionDep,
        user: CurrentUser,
        child_id: Annotated[uuid.UUID, Query(description="The child whose data to read.")],
    ) -> ChildAccess:
        return await require_child_access(session, user, child_id, required_role)

    return dependency


async def _uuid_from_body(request: Request, field: str) -> uuid.UUID:
    """Pull one id out of the already-parsed JSON body.

    Reading the body here rather than re-declaring it keeps the handler's own body model as
    the single description of the payload. Starlette caches the bytes, so this is not a
    second read.
    """
    try:
        body = await request.json()
    except ValueError as exc:
        raise RascalError(ErrorCode.VALIDATION_FAILED, "Body must be JSON.") from exc
    raw = body.get(field) if isinstance(body, dict) else None
    if raw is None:
        raise RascalError(ErrorCode.VALIDATION_FAILED, f"{field} is required.", field=field)
    try:
        return uuid.UUID(str(raw))
    except ValueError as exc:
        raise RascalError(
            ErrorCode.VALIDATION_FAILED, f"{field} must be a UUID.", field=field
        ) from exc


def child_access_from_body(required_role: GuardianRole = "parent") -> ChildAccessDependency:
    """For routes that name the child in the JSON body, like `POST /entries`."""

    async def dependency(
        request: Request,
        session: SessionDep,
        user: CurrentUser,
    ) -> ChildAccess:
        child_id = await _uuid_from_body(request, "child_id")
        return await require_child_access(session, user, child_id, required_role)

    return dependency


def entry_access_from_body(required_role: GuardianRole = "parent") -> ChildAccessDependency:
    """For routes that name the *entry* in the body, like `POST /media/upload-url`."""

    async def dependency(
        request: Request,
        session: SessionDep,
        user: CurrentUser,
    ) -> ChildAccess:
        entry_id = await _uuid_from_body(request, "entry_id")
        child_id = await session.scalar(select(Entry.child_id).where(Entry.id == entry_id))
        if child_id is None:
            raise not_found("Entry")
        return await require_child_access(session, user, child_id, required_role)

    return dependency


def entry_access(required_role: GuardianRole = "viewer") -> ChildAccessDependency:
    """Resolves the child that owns an entry, then runs the same check."""

    async def dependency(
        session: SessionDep,
        user: CurrentUser,
        entry_id: Annotated[uuid.UUID, Path()],
    ) -> ChildAccess:
        child_id = await session.scalar(select(Entry.child_id).where(Entry.id == entry_id))
        if child_id is None:
            raise not_found("Entry")
        return await require_child_access(session, user, child_id, required_role)

    return dependency


def media_access(required_role: GuardianRole = "viewer") -> ChildAccessDependency:
    """Resolves the child that owns a media row through its entry."""

    async def dependency(
        session: SessionDep,
        user: CurrentUser,
        media_id: Annotated[uuid.UUID, Path()],
    ) -> ChildAccess:
        child_id = await session.scalar(
            select(Entry.child_id)
            .join(Media, Media.entry_id == Entry.id)
            .where(Media.id == media_id)
        )
        if child_id is None:
            raise not_found("Media")
        return await require_child_access(session, user, child_id, required_role)

    return dependency


def assignment_access(required_role: GuardianRole = "viewer") -> ChildAccessDependency:
    """Resolves the child that owns an assignment."""

    async def dependency(
        session: SessionDep,
        user: CurrentUser,
        assignment_id: Annotated[uuid.UUID, Path()],
    ) -> ChildAccess:
        child_id = await session.scalar(
            select(Assignment.child_id).where(Assignment.id == assignment_id)
        )
        if child_id is None:
            raise not_found("Assignment")
        return await require_child_access(session, user, child_id, required_role)

    return dependency


# The two roles, named once so route signatures read as intent rather than as strings.
ReadAccess = Annotated[ChildAccess, Depends(child_access("viewer"))]
WriteAccess = Annotated[ChildAccess, Depends(child_access("parent"))]
