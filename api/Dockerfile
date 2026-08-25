# syntax=docker/dockerfile:1

# --- Build ---------------------------------------------------------------------------------
# Dependencies resolve from uv.lock into a self-contained virtualenv. Nothing from this stage
# reaches the runtime image except that virtualenv and the application source.
FROM python:3.12-slim-bookworm AS build

# Must be able to read uv.lock's format. The committed lock is revision 3, which uv
# 0.5.x does not understand — `uv sync --frozen` rejects it outright.
COPY --from=ghcr.io/astral-sh/uv:0.8.17 /uv /usr/local/bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

# The lockfile alone in its own layer, so a source-only change does not reinstall the world.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project

COPY src ./src
COPY alembic.ini ./
COPY alembic ./alembic
COPY seeds ./seeds
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev


# --- Runtime -------------------------------------------------------------------------------
FROM python:3.12-slim-bookworm AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/app/.venv/bin:$PATH"

# **ffmpeg, for one feature.** The studio's video is recorded in the operator's browser as
# VP9-in-WebM and no platform publishes that, so it is re-encoded to H.264 here — see
# `services/social/transcode.py` and the scope note in `CLAUDE.md`. `ffprobe` comes in the same
# package and the test suite probes what came out with it.
#
# ~~*The studio's video render generates a clip per shot and no video API joins them, so the
# concatenation happens here — see `services/social/stitch.py`.*~~ — **struck Aug 25, 2026 by
# phase 120: there are no clips and `stitch.py` is deleted.** The install stays for the
# re-encode, which is the half that was always load-bearing.
#
# **This is not a small install: measured at +148 MB** on this exact base image — 43 MB for
# `python:3.12-slim-bookworm`, 191 MB once ffmpeg is in. Debian's `ffmpeg` is the full suite
# and brings its codec libraries whatever `--no-install-recommends` does; that flag trims the
# recommends, not the dependencies. It is the price of the feature, and the number is here
# rather than discovered in a registry bill.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Non-root. The process needs to read the image and write nothing.
RUN groupadd --system --gid 1001 rascal \
    && useradd --system --uid 1001 --gid rascal --create-home rascal

WORKDIR /app

COPY --from=build --chown=rascal:rascal /app /app

USER rascal

EXPOSE 8080

# Fly's proxy terminates TLS and forwards to this port. One worker: Postgres connection
# counts on Neon are the scarce resource, and scaling out means more machines, not more
# workers inside one.
CMD ["uvicorn", "rascal.main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
