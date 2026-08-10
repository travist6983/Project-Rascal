"""Prove a deployed RASCAL API actually works. Not a checklist — a program.

    uv run python scripts/verify_deployment.py --base-url https://rascal-api.fly.dev

Runs against any base URL, including http://localhost:8000. Six checks, in the order that a
failure is cheapest to understand:

  1. `/health` answers, and it answers `ok/ok`, which means the app reached its database.
  2. The database is migrated to the revision this checkout expects — not merely *a*
     revision, the head. A running app in front of a stale schema is the failure mode the
     Fly release command exists to prevent, and this is how you confirm it did.
  3. `dev-login` and the `/debug/*` routes are absent. If either answers, `ENVIRONMENT` is
     not `prod` and anyone can mint a session against the real archive.
  4. A bearer token round-trips: `GET /v1/me` returns the user the token names.
  5. **`GET /today` fills a brand-new child's day on a database where the scheduler has
     never run.** This is the one check that cannot be inferred from the others, and the
     reason the archive survives a stopped machine.
  6. Object storage: presign, PUT the bytes, complete, presign a read, GET the bytes back
     and compare them. Against the real store — a stub proves nothing about production.

**It needs the database, not just the URL.** Checks 2 and 4 cannot be done over HTTP: there
is no route that reports the schema revision, and `POST /v1/auth/dev-login` is deliberately
compiled out of a production build (see docs/blocked.md), so a token has to be minted with
the same `JWT_SECRET` the deployment signs with. Export `DIRECT_DATABASE_URL` (or
`DATABASE_URL`) and `JWT_SECRET` before running. `docs/runbook-deploy.md` §7 has the exact
commands.

**It writes to the archive it is verifying**, and then cleans up after itself: one user, one
child named `deploy-verify`, and whatever check 5 and check 6 create beneath them. Deleting
the child cascades to its assignments, entries and media rows; the user goes last, because
`entries.author_id` is `ON DELETE RESTRICT`. Pass `--keep` to leave it all behind and go and
look at it. The uploaded object is *not* removed — the script has no storage credentials, it
only ever holds presigned URLs — so its key is printed for you to delete by hand.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import sys
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

import httpx
import sqlalchemy as sa
from alembic.config import Config
from alembic.script import ScriptDirectory

from rascal.config import DatabaseSettings
from rascal.services.tokens import create_access_token

API_DIR = Path(__file__).resolve().parents[1]

# A 1x1 transparent PNG. Small enough to stay well under the multipart threshold, and a real
# image rather than a text file, so `content_type` is not a lie the store might notice.
PIXEL = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4"
    "890000000a49444154789c6360000002000100ffff03000006000557bfabd400"
    "00000049454e44ae426082"
)

VERIFY_CHILD_NAME = "deploy-verify"


class VerifierSettings(DatabaseSettings):
    """A connection string and a signing key, and nothing else.

    Deliberately not the app's `Settings`: verifying a deployment should not require an
    operator to invent an Apple bundle id and a bucket name on their laptop for values this
    script never reads. `DatabaseSettings` exists for exactly this reason — see the note on
    it in `rascal/config.py` — and this duck-types into `create_access_token`, which touches
    only the two fields below.
    """

    jwt_secret: str
    # The token's only job is to outlive the next few seconds of HTTP calls.
    access_token_ttl_minutes: int = 15


@dataclass
class Result:
    name: str
    ok: bool
    detail: str


class Verifier:
    def __init__(self, base_url: str, *, skip_storage: bool, keep: bool) -> None:
        self.base = base_url.rstrip("/")
        self.skip_storage = skip_storage
        self.keep = keep
        self.results: list[Result] = []
        self.settings = VerifierSettings()  # type: ignore[call-arg]
        self.engine = sa.create_engine(self.settings.sync_database_url, future=True)
        self.http = httpx.Client(timeout=30.0, follow_redirects=False)
        self.user_id: uuid.UUID | None = None
        self.child_id: uuid.UUID | None = None
        self.orphaned_key: str | None = None

    # --- plumbing --------------------------------------------------------------------------

    def record(self, name: str, ok: bool, detail: str) -> bool:
        self.results.append(Result(name, ok, detail))
        print(f"{'PASS' if ok else 'FAIL'}  {name}\n      {detail}")
        return ok

    def get(self, path: str, **kwargs) -> httpx.Response:
        return self.http.get(f"{self.base}{path}", **kwargs)

    def post(self, path: str, **kwargs) -> httpx.Response:
        return self.http.post(f"{self.base}{path}", **kwargs)

    @property
    def auth(self) -> dict[str, str]:
        assert self.user_id is not None
        token, _ = create_access_token(self.user_id, self.settings)  # type: ignore[arg-type]
        return {"Authorization": f"Bearer {token}"}

    # --- the checks ------------------------------------------------------------------------

    def check_health(self) -> bool:
        try:
            response = self.get("/health")
        except httpx.HTTPError as exc:
            return self.record("health", False, f"{self.base}/health is unreachable: {exc}")
        body = response.text.strip()
        if response.status_code != 200:
            return self.record("health", False, f"HTTP {response.status_code}: {body[:200]}")
        payload = response.json()
        if payload != {"status": "ok", "db": "ok"}:
            return self.record(
                "health",
                False,
                f"expected {{'status':'ok','db':'ok'}}, got {payload}. The app is serving but "
                "cannot reach its database — check DATABASE_URL.",
            )
        return self.record("health", True, f"{self.base}/health -> ok/ok")

    def check_migrations(self) -> bool:
        config = Config(str(API_DIR / "alembic.ini"))
        config.set_main_option("script_location", str(API_DIR / "alembic"))
        expected = set(ScriptDirectory.from_config(config).get_heads())

        with self.engine.connect() as conn:
            if not sa.inspect(conn).has_table("alembic_version"):
                return self.record(
                    "migrations",
                    False,
                    "no alembic_version table: nothing has ever been migrated here. The Fly "
                    "release command (`alembic upgrade head`) did not run.",
                )
            applied = {
                row[0] for row in conn.execute(sa.text("SELECT version_num FROM alembic_version"))
            }

        if applied != expected:
            return self.record(
                "migrations",
                False,
                f"database is at {sorted(applied)}, this checkout's head is {sorted(expected)}. "
                "The app is serving in front of the wrong schema.",
            )
        return self.record("migrations", True, f"at head: {sorted(expected)}")

    def check_production_hygiene(self) -> bool:
        """`dev-login` and `/debug/*` must not exist. This is a safety property, not a nicety."""
        ok = True
        for path in ("/v1/auth/dev-login", "/v1/debug/scheduler/run"):
            response = self.post(path, json={})
            if response.status_code != 404:
                ok = self.record(
                    "production hygiene",
                    False,
                    f"POST {path} answered {response.status_code}, expected 404. ENVIRONMENT is "
                    "not 'prod', and the fixture login is reachable on the real archive.",
                )
        if ok:
            ok = self.record(
                "production hygiene", True, "dev-login and /debug/* are both absent (404)"
            )
        return ok

    def check_auth(self) -> bool:
        """Mint a token for a user this script creates, and see whether the API believes it."""
        self.user_id = uuid.uuid4()
        with self.engine.begin() as conn:
            conn.execute(
                sa.text("INSERT INTO users (id, display_name, email) VALUES (:id, :name, :email)"),
                {
                    "id": self.user_id,
                    "name": "Deploy verification",
                    "email": f"deploy-verify+{self.user_id.hex[:8]}@example.invalid",
                },
            )

        response = self.get("/v1/me", headers=self.auth)
        if response.status_code != 200:
            return self.record(
                "auth",
                False,
                f"GET /v1/me answered {response.status_code}: {response.text[:200]}. If this is "
                "401, the JWT_SECRET in this environment is not the one the deployment signs "
                "with.",
            )
        if response.json().get("id") != str(self.user_id):
            return self.record(
                "auth", False, f"/v1/me returned a different user: {response.json()}"
            )
        return self.record("auth", True, f"bearer token round-trips as {self.user_id}")

    def check_today_fills_itself(self) -> bool:
        """The Phase A proof, against a real deployment.

        The child is brand new, so no scheduler run — past or future — can have touched it.
        If `/today` comes back with work in it, the read path created that work.
        """
        created = self.post(
            "/v1/children",
            headers=self.auth,
            json={
                "name": VERIFY_CHILD_NAME,
                "birthdate": "2022-06-14",
                "family_timezone": "America/Detroit",
            },
        )
        if created.status_code != 201:
            return self.record(
                "today fills itself",
                False,
                f"POST /v1/children answered {created.status_code}: {created.text[:200]}",
            )
        self.child_id = uuid.UUID(created.json()["id"])

        with self.engine.connect() as conn:
            existing = conn.execute(
                sa.text("SELECT count(*) FROM assignments WHERE child_id = :id"),
                {"id": self.child_id},
            ).scalar_one()
        if existing:
            return self.record(
                "today fills itself",
                False,
                f"a new child already has {existing} assignment(s); the premise of this check "
                "is broken and its result would mean nothing.",
            )

        first = self.get(f"/v1/children/{self.child_id}/today", headers=self.auth)
        if first.status_code != 200:
            return self.record(
                "today fills itself",
                False,
                f"GET /today answered {first.status_code}: {first.text[:200]}",
            )
        body = first.json()
        slots = {item["slot"] for item in body["today"]}
        if not {"question", "mission"} <= slots:
            return self.record(
                "today fills itself",
                False,
                f"/today returned slots {sorted(slots)} for a child with no assignments. The "
                "read path did not fill the day — or the prompt library is not seeded.",
            )

        with self.engine.connect() as conn:
            rows = conn.execute(
                sa.text(
                    "SELECT slot, assigned_on FROM assignments WHERE child_id = :id ORDER BY slot"
                ),
                {"id": self.child_id},
            ).all()
        dates = {row.assigned_on.isoformat() for row in rows}
        if dates != {body["date"]}:
            return self.record(
                "today fills itself",
                False,
                f"rows were written for {sorted(dates)} but /today reported {body['date']}",
            )

        # And it is a no-op the second time: same rows, no duplicate slot.
        second = self.get(f"/v1/children/{self.child_id}/today", headers=self.auth)
        with self.engine.connect() as conn:
            after = (
                conn.execute(
                    sa.text("SELECT slot FROM assignments WHERE child_id = :id"),
                    {"id": self.child_id},
                )
                .scalars()
                .all()
            )
        if second.status_code != 200 or len(after) != len(rows) or len(set(after)) != len(after):
            return self.record(
                "today fills itself",
                False,
                f"a second read was not a no-op: {len(rows)} rows became {len(after)} ({after})",
            )

        return self.record(
            "today fills itself",
            True,
            f"a child with no scheduler history got {sorted(slots)} for {body['date']}, and a "
            "second read created nothing",
        )

    def check_object_storage(self) -> bool:
        """Presign, upload, complete, download, compare. Against the real store."""
        assert self.child_id is not None
        entry_id = uuid.uuid4()
        entry = self.post(
            "/v1/entries",
            headers=self.auth,
            json={
                "id": str(entry_id),
                "child_id": str(self.child_id),
                "occurred_at": dt.datetime.now(tz=dt.UTC).isoformat(),
                "title": "deploy verification",
            },
        )
        if entry.status_code not in (200, 201):
            return self.record(
                "object storage",
                False,
                f"POST /v1/entries answered {entry.status_code}: {entry.text[:200]}",
            )

        presigned = self.post(
            "/v1/media/upload-url",
            headers=self.auth,
            json={
                "entry_id": str(entry_id),
                "kind": "photo",
                "filename": "deploy-verify.png",
                "bytes": len(PIXEL),
                "content_type": "image/png",
            },
        )
        if presigned.status_code != 200:
            return self.record(
                "object storage",
                False,
                f"POST /v1/media/upload-url answered {presigned.status_code}: "
                f"{presigned.text[:200]}",
            )
        plan = presigned.json()
        upload_url = plan["upload_url"]
        if not upload_url:
            return self.record(
                "object storage",
                False,
                f"a {len(PIXEL)}-byte object was planned as multipart, which cannot be right: "
                f"{plan}",
            )

        host = urlparse(upload_url).hostname or ""
        if host.endswith("amazonaws.com"):
            return self.record(
                "object storage",
                False,
                f"the presigned URL points at {host}. S3_ENDPOINT_URL is unset, so the app is "
                "signing for real AWS while the bucket lives on Tigris. This fails only in "
                "production and only at upload time.",
            )

        put = self.http.put(upload_url, content=PIXEL, headers={"Content-Type": "image/png"})
        if put.status_code not in (200, 201, 204):
            return self.record(
                "object storage",
                False,
                f"PUT to {host} answered {put.status_code}: {put.text[:200]}. The signature was "
                "rejected — check S3_REGION (Tigris wants 'auto') and the access key's bucket "
                "role.",
            )
        # Only now: an object exists in the bucket, and cleanup cannot reach it.
        self.orphaned_key = plan["s3_key"]

        media_id = plan["media_id"]
        completed = self.post(f"/v1/media/{media_id}/complete", headers=self.auth, json={})
        if completed.status_code != 200:
            return self.record(
                "object storage",
                False,
                f"POST /v1/media/{media_id}/complete answered {completed.status_code}: "
                f"{completed.text[:200]}",
            )

        download = self.get(f"/v1/media/{media_id}/url", headers=self.auth)
        if download.status_code != 200:
            return self.record(
                "object storage",
                False,
                f"GET /v1/media/{media_id}/url answered {download.status_code}: "
                f"{download.text[:200]}",
            )
        fetched = self.http.get(download.json()["url"])
        if fetched.status_code != 200 or fetched.content != PIXEL:
            return self.record(
                "object storage",
                False,
                f"the bytes did not come back: HTTP {fetched.status_code}, "
                f"{len(fetched.content)} bytes of an expected {len(PIXEL)}. The object was "
                "written but cannot be read, so the archive is write-only.",
            )

        return self.record(
            "object storage",
            True,
            f"{len(PIXEL)} bytes round-tripped through {host} at key {plan['s3_key']}",
        )

    # --- cleanup ---------------------------------------------------------------------------

    def cleanup(self) -> None:
        if self.keep:
            print(f"\n--keep: left user {self.user_id} and child {self.child_id} in the database.")
            return
        with self.engine.begin() as conn:
            # The child first: entries, media, assignments and guardians cascade from it, and
            # `entries.author_id` is ON DELETE RESTRICT, so the user cannot go until they have.
            if self.child_id is not None:
                conn.execute(sa.text("DELETE FROM children WHERE id = :id"), {"id": self.child_id})
            if self.user_id is not None:
                conn.execute(sa.text("DELETE FROM users WHERE id = :id"), {"id": self.user_id})
        if self.orphaned_key:
            print(
                f"\nThe uploaded object was left behind — this script holds presigned URLs, not "
                f"storage credentials. Remove it with:\n"
                f'  aws s3 rm "s3://$S3_BUCKET/{self.orphaned_key}" '
                f"--endpoint-url https://t3.storage.dev"
            )

    def guarded(self, name: str, check: Callable[[], bool]) -> bool:
        """Turn a network failure into a recorded result rather than a stack trace.

        These checks reach three different hosts — the app, the object store, and whatever
        proxy sits between. Any of them can refuse a connection, and someone reading this
        output at 11pm needs a line that says which check died and why, not a traceback that
        makes the *script* look like the broken thing.
        """
        try:
            return check()
        except httpx.HTTPError as exc:
            return self.record(name, False, f"{type(exc).__name__}: {exc}")

    def run(self) -> int:
        print(f"Verifying {self.base}\n")
        if not self.guarded("health", self.check_health):
            print("\nStopping: nothing below this can mean anything if the app is not serving.")
            return 1

        self.check_migrations()
        self.guarded("production hygiene", self.check_production_hygiene)

        reached_a_child = self.guarded("auth", self.check_auth) and self.guarded(
            "today fills itself", self.check_today_fills_itself
        )
        if self.skip_storage:
            print("SKIP  object storage\n      --skip-storage")
        elif reached_a_child:
            self.guarded("object storage", self.check_object_storage)

        self.cleanup()

        failed = [result for result in self.results if not result.ok]
        print(f"\n{len(self.results) - len(failed)}/{len(self.results)} checks passed")
        if failed:
            print("Failed: " + ", ".join(result.name for result in failed))
        return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--base-url", required=True, help="e.g. https://rascal-api.fly.dev or http://localhost:8000"
    )
    parser.add_argument(
        "--skip-storage",
        action="store_true",
        help="Skip the Tigris round trip. Everything else still runs.",
    )
    parser.add_argument(
        "--keep",
        action="store_true",
        help="Leave the verification user and child in the database instead of deleting them.",
    )
    args = parser.parse_args(argv)

    missing = [name for name in ("JWT_SECRET",) if not os.environ.get(name)]
    if not (os.environ.get("DIRECT_DATABASE_URL") or os.environ.get("DATABASE_URL")):
        missing.append("DATABASE_URL (or DIRECT_DATABASE_URL)")
    if missing:
        print(
            "These checks need the deployment's own configuration, not just its URL:\n  "
            + "\n  ".join(missing)
            + "\n\nSee docs/runbook-deploy.md section 7.",
            file=sys.stderr,
        )
        return 2

    verifier = Verifier(args.base_url, skip_storage=args.skip_storage, keep=args.keep)
    try:
        return verifier.run()
    finally:
        verifier.http.close()
        verifier.engine.dispose()


if __name__ == "__main__":
    sys.exit(main())
