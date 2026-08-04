"""`GET /health` is the only unauthenticated route outside the auth endpoints."""

from __future__ import annotations

from httpx import AsyncClient


async def test_health_reports_ok_and_touches_the_database(client: AsyncClient) -> None:
    response = await client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok", "db": "ok"}


async def test_health_needs_no_bearer_token(client: AsyncClient) -> None:
    # No Authorization header at all, and still a 200 — Fly's health check has no credentials.
    assert (await client.get("/health")).status_code == 200


async def test_unknown_route_uses_the_standard_error_shape(client: AsyncClient) -> None:
    response = await client.get("/nope")

    assert response.status_code == 404
    assert response.json() == {
        "error": {"code": "not_found", "message": "Not Found", "field": None}
    }
