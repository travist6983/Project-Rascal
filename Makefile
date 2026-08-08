SHELL := /bin/bash
API := api

# .env at the repo root is the single source of configuration for every target.
ifneq (,$(wildcard .env))
include .env
export
endif

# Every uv invocation runs from api/ so pyproject.toml is both the project and the
# pytest/ruff config root.
RUN := cd $(API) && uv run

# tests/test_restore.py shells out to pg_dump and psql for a real dump/restore round trip,
# and the client major version has to match the server's. A *newer* client is not safe here:
# pg_dump 17 writes `SET transaction_timeout` into the dump header, Postgres 16 does not
# recognise that parameter, and the restore dies with an error that never mentions versions.
# Postgres 16 is what compose runs and what Neon runs, so prefer a 16 client when one is
# installed rather than whatever happens to be first on PATH.
PG16_BIN := $(firstword $(wildcard /opt/homebrew/opt/postgresql@16/bin \
                                   /usr/local/opt/postgresql@16/bin \
                                   /usr/lib/postgresql/16/bin))
ifneq (,$(PG16_BIN))
export PATH := $(PG16_BIN):$(PATH)
endif

# Where `make fixtures` points. Defaults to the local API from `make dev`; override for a
# deployed one:  make fixtures API_BASE=https://rascal-api.fly.dev
API_BASE ?= http://localhost:8000
FIXTURES := ios/Fixtures

.PHONY: help up down dev test lint fmt migrate revision seed reset-db psql install fixtures

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

install: ## Sync dependencies into api/.venv
	cd $(API) && uv sync --all-groups

up: ## Start Postgres 16 and wait for it to be healthy
	docker compose up -d --wait postgres

down: ## Stop Postgres (keeps the named volume)
	docker compose down

dev: install ## Run the API with reload at http://localhost:8000 (docs at /docs)
	$(RUN) uvicorn rascal.main:app --reload --host 0.0.0.0 --port 8000

test: install ## Run the test suite against a real Postgres
	$(RUN) pytest -q

# `../.github` is included because CI lints it. A target that checks less than CI does is
# how a formatting failure gets discovered by the pull request instead of by the developer.
lint: install ## Lint and check formatting
	$(RUN) ruff check . ../.github
	$(RUN) ruff format --check . ../.github

fmt: install ## Autofix lint and format
	$(RUN) ruff check --fix . ../.github
	$(RUN) ruff format . ../.github

migrate: install ## Apply all migrations
	$(RUN) alembic upgrade head

revision: install ## Create a migration: make revision m="add widgets"
	@test -n "$(m)" || (echo 'usage: make revision m="your message"' && exit 1)
	$(RUN) alembic revision -m "$(m)"

seed: install ## Load api/seeds/prompts.yaml into the prompts table (idempotent)
	$(RUN) python -m rascal.jobs.seed

scheduler: install ## Run the daily scheduler for today (optional: d=2026-08-14)
	$(RUN) python -m rascal.jobs.scheduler $(if $(d),--date $(d),)

reset-db: ## Drop the schema and re-migrate from scratch, then reseed
	$(RUN) alembic downgrade base
	$(RUN) alembic upgrade head
	$(RUN) python -m rascal.jobs.seed

psql: ## Open a psql shell against the dev database
	docker compose exec postgres psql -U rascal -d rascal

# Ground truth for the iOS client's JSON shape, captured from a running API rather than
# hand-written — a hand-written fixture is a guess that drifts. Every response lands in a
# temp file and is checked for a 2xx and for being parseable JSON *before* it is moved into
# ios/Fixtures/, because a silently captured 401 body is worse than no fixture at all: the
# client would be built against the error shape. Re-run whenever a response shape changes.
fixtures: ## Capture real API responses into ios/Fixtures/ (override: API_BASE=https://...)
	@set -euo pipefail; \
	command -v jq >/dev/null 2>&1 || { echo "make fixtures needs jq — brew install jq" >&2; exit 1; }; \
	tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	get() { \
	  local label="$$1" out="$$2"; shift 2; \
	  local code; \
	  code=$$(curl -sS -o "$$out" -w '%{http_code}' --max-time 20 "$$@" 2>/dev/null || true); \
	  if [ -z "$$code" ] || [ "$$code" = "000" ]; then \
	    echo "" >&2; echo "  $$label -> no response from $(API_BASE)" >&2; \
	    echo "  Is the API running? \`make up && make dev\`" >&2; exit 1; \
	  fi; \
	  if [ "$$code" != "200" ]; then \
	    echo "" >&2; echo "  $$label -> HTTP $$code (expected 200)" >&2; \
	    if [ -s "$$out" ]; then echo "  response body:" >&2; sed 's/^/    /' "$$out" >&2 || true; fi; echo "" >&2; \
	    if [ "$$code" = "404" ] && [ "$$label" = "POST /v1/auth/dev-login" ]; then \
	      echo "  A 404 here means the API is not running with ENVIRONMENT=local." >&2; \
	      echo "  dev-login is only mounted in a local build — see docs/api-contract.md." >&2; \
	    fi; \
	    echo "  No fixture written." >&2; exit 1; \
	  fi; \
	  jq -e . "$$out" >/dev/null 2>&1 || { \
	    echo "  $$label returned 200 but the body is not JSON. No fixture written." >&2; exit 1; }; \
	  echo "  $$label -> 200"; \
	}; \
	echo "capturing fixtures from $(API_BASE)"; \
	get "POST /v1/auth/dev-login" "$$tmp/dev-login.json" \
	  -X POST "$(API_BASE)/v1/auth/dev-login" \
	  -H 'content-type: application/json' -d '{}'; \
	token=$$(jq -r '.access_token // empty' "$$tmp/dev-login.json"); \
	[ -n "$$token" ] || { echo "  dev-login returned no access_token. No fixture written." >&2; exit 1; }; \
	get "GET /v1/children" "$$tmp/children.json" \
	  "$(API_BASE)/v1/children" -H "authorization: Bearer $$token"; \
	child=$$(jq -r '.[0].id // empty' "$$tmp/children.json"); \
	if [ -z "$$child" ]; then \
	  echo "" >&2; \
	  echo "  The fixture account has no children, so there is no /today to capture." >&2; \
	  echo "  dev-login creates a user, never a child, and \`make seed\` loads prompts only." >&2; \
	  echo "  Create one, then re-run:" >&2; \
	  echo "" >&2; \
	  echo "    curl -sS -X POST $(API_BASE)/v1/children \\" >&2; \
	  echo "      -H \"authorization: Bearer \$$TOKEN\" -H 'content-type: application/json' \\" >&2; \
	  echo "      -d '{\"name\":\"Rascal\",\"birthdate\":\"2021-06-01\",\"family_timezone\":\"America/Detroit\"}'" >&2; \
	  echo "" >&2; \
	  echo "  No fixture written." >&2; exit 1; \
	fi; \
	get "GET /v1/children/$$child/today" "$$tmp/today.json" \
	  "$(API_BASE)/v1/children/$$child/today" -H "authorization: Bearer $$token"; \
	mkdir -p $(FIXTURES); \
	for f in dev-login today; do jq . "$$tmp/$$f.json" > "$(FIXTURES)/$$f.json"; done; \
	echo "wrote $(FIXTURES)/dev-login.json and $(FIXTURES)/today.json"
