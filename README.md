# PolicyLedger

A synthetic life-insurance policy registry, built and deployed the way a regulated fintech would: hardened containers, Kubernetes, Terraform, CI security gates, and monitoring.

**This project is inspired by infineo's public description of what they do — turning life-insurance policies into structured, tradable assets — and is not a copy of their system.** No infineo logos, branding, or real data are used anywhere here. All carriers, policies, and cash surrender values in this repo are invented.

Why this repo exists: I'm being considered for a Platform Engineer role and wanted to show real, explainable infrastructure work rather than just claim I know the tools. Every file here I can walk through and explain out loud, including what broke while building it.

## Status

Day 1 of 4 (service + hardened container) is in progress. Not yet built: Kubernetes manifests, Terraform, CI/CD, monitoring, the deliberate incident. See [CLAUDE.md](CLAUDE.md) for the full day-by-day plan and acceptance criteria.

## What's here so far

- **`app/`** — a FastAPI service backed by Postgres. Endpoints: `GET /healthz`, `GET /policies`, `POST /policies`, `PATCH /policies/{id}`.
- **Append-only audit log** — every create/update also writes a row to `audit_log` (who via an `X-Actor` header, what changed, before/after snapshots, when). There is no update or delete code path for that table anywhere in the app — "append-only" here means "nothing in this codebase can rewrite history," not a database-level guarantee (see Honesty notes).
- **`Dockerfile`** — multi-stage build, runs as a non-root user, pinned base image (`python:3.12-slim`), dependencies installed into an isolated virtualenv in a separate build stage so the final image doesn't carry build tools.
- **`docker-compose.yml`** — runs the API and Postgres together locally.
- **`seed/seed.py`** — posts ~15 fake policies to a running API so there's something to look at.
- **`tests/`** — pytest suite (5 tests) covering the endpoints and, directly, that audit rows actually land in the database on writes. Tests run against SQLite in-memory, not Postgres, so they don't require Docker (see Honesty notes).

## Running it locally

```bash
docker compose up --build
```

Then, in another terminal:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
python seed/seed.py
curl http://localhost:8000/policies
```

Run the tests (no Docker needed):

```bash
source .venv/bin/activate
pip install -r requirements-dev.txt
python -m pytest tests/ -v
```

## Image size

*To be filled in once Docker Desktop is installed and `docker compose up --build` has actually run — I'm not going to write a number I haven't measured.*

## Honesty notes (what's not enforced / not tested / simulated)

- **"Append-only" is enforced by omission, not by a database constraint.** No route or code path in this app updates or deletes `audit_log` rows. A Postgres role with `REVOKE UPDATE, DELETE` on that table would make this a DB-level guarantee instead of an application-level convention; that's not set up yet.
- **Actor identity is a trusted client-supplied header (`X-Actor`), not authentication.** There's no login system in this project. A real system would derive the actor from a verified session/token, not let the caller self-report it.
- **Tests run against SQLite, not Postgres**, because Docker wasn't available in this environment when they were first written. This is faster and needs no daemon, but it means Postgres-specific behavior (e.g. `NUMERIC` precision edge cases) isn't exercised by the test suite yet.
- **Base image versions aren't hash-pinned**, only tag-pinned (`python:3.12-slim`, `postgres:16-alpine`). Tags can move; a stricter setup would pin by digest.
- Docker Desktop, kubectl, kind, helm, terraform, gitleaks, and trivy are not yet installed on the machine this was built on — see "What broke and how I fixed it" below.

## What broke and how I fixed it

- **`Base.metadata.create_all()` was running at import time**, using the default (Postgres) `DATABASE_URL`. That meant even the test suite — which is supposed to use an in-memory SQLite database instead — tried to open a real Postgres connection during test collection and failed with `connection to server ... failed: Connection refused`. Fix: moved table creation into a FastAPI `lifespan` startup hook, so it only runs when the app actually starts, using whichever engine is configured at that point — and the test fixture patches that engine before startup runs.
- **Homebrew's `docker-desktop` cask install failed** while trying to symlink `docker-credential-osxkeychain` into `/usr/local/bin`, because that step needs `sudo` and an interactive terminal for the password prompt, which isn't available in this automated environment. Docker Desktop needs to be installed manually (`brew install --cask docker`, then approve the password prompt, then open Docker.app once to finish setup) before `docker compose up` can be run.

## Repo layout

See [CLAUDE.md](CLAUDE.md) for the full target layout and 4-day plan.
