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

.PHONY: help up down dev test lint fmt migrate revision seed reset-db psql install

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
