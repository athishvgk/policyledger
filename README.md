# PolicyLedger

A synthetic life-insurance policy registry, built and deployed the way a regulated fintech would: hardened containers, Kubernetes, Terraform, CI security gates, and monitoring.

**This project is inspired by infineo's public description of what they do — turning life-insurance policies into structured, tradable assets — and is not a copy of their system.** No infineo logos, branding, or real data are used anywhere here. All carriers, policies, and cash surrender values in this repo are invented.

Why this repo exists: I'm being considered for a Platform Engineer role and wanted to show real, explainable infrastructure work rather than just claim I know the tools. Every file here I can walk through and explain out loud, including what broke while building it.

## Status

Day 3 of 4 (CI/CD with security gates) is done: [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs tests, `gitleaks`, `terraform fmt`/`validate`, `trivy config` on `terraform/` and `k8s/`, builds the image with Buildx (GitHub Actions layer cache), scans it with `trivy image`, pushes to GHCR on `main` only, and deploys to a throwaway `kind` cluster in CI to curl `/healthz` as a smoke test. Not yet built: Grafana dashboard/alerts, the deliberate incident. See [CLAUDE.md](CLAUDE.md) for the full day-by-day plan and acceptance criteria.

## What's here so far

- **`app/`** — a FastAPI service backed by Postgres. Endpoints: `GET /healthz`, `GET /policies`, `POST /policies`, `PATCH /policies/{id}`.
- **Append-only audit log** — every create/update also writes a row to `audit_log` (who via an `X-Actor` header, what changed, before/after snapshots, when). There is no update or delete code path for that table anywhere in the app — "append-only" here means "nothing in this codebase can rewrite history," not a database-level guarantee (see Honesty notes).
- **`Dockerfile`** — multi-stage build, runs as a non-root user, pinned base image (`python:3.12-slim`), dependencies installed into an isolated virtualenv in a separate build stage so the final image doesn't carry build tools.
- **`docker-compose.yml`** — runs the API and Postgres together locally.
- **`seed/seed.py`** — posts ~15 fake policies to a running API so there's something to look at.
- **`tests/`** — pytest suite (5 tests) covering the endpoints and, directly, that audit rows actually land in the database on writes. Tests run against SQLite in-memory, not Postgres, so they don't require Docker (see Honesty notes).
- **`terraform/`** — provisions a local `kind` (Kubernetes-in-Docker) cluster and installs `kube-prometheus-stack` into it via the `helm` provider. Nothing here touches any cloud account; `apply`/`destroy` only create and remove local Docker containers.
- **`k8s/`** — manifests for the app itself: namespace, Postgres (Deployment + PVC + Service), the API (Deployment, 2 replicas, hardened `securityContext`, resource limits, `/healthz` probes), a Secret template (see below), and a NetworkPolicy restricting Postgres to the API pod.
- **`.github/workflows/ci.yml`** — five jobs on every push/PR: unit tests, a `gitleaks` secret scan, `terraform fmt`/`validate`, a `trivy config` scan of `terraform/` and `k8s/`, and a build that's scanned with `trivy image` before anything is pushed. On `main` only, the scanned image is pushed to GHCR tagged with the commit SHA, and a separate job spins up a throwaway `kind` cluster in the runner, deploys the app to it, and curls `/healthz` for real — not just "tests passed."

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

To verify the audit log directly against Postgres, rather than trusting the API's own responses:

```bash
docker compose exec postgres psql -U policyledger -d policyledger \
  -c "SELECT count(*) FROM policies;" \
  -c "SELECT count(*) FROM audit_log;"
```

After `docker compose up --build` + `python seed/seed.py` (15 policies) + one manual `POST`, this returned 16 and 16 — one audit row per policy, matching.

## Running it on Kubernetes (local kind cluster)

```bash
cd terraform
terraform init
terraform apply          # builds a local kind cluster + kube-prometheus-stack

# kind runs its own containers -- it can't see images from `docker build`
# until you explicitly load one in.
cd ..
docker build -t policyledger-api:local .
kind load docker-image policyledger-api:local --name policyledger

# The real Secret is generated locally, never committed (see
# k8s/02-secret.yaml.example for the template and why).
kubectl create secret generic policyledger-secret \
  --namespace policyledger \
  --from-literal=POSTGRES_PASSWORD='policyledger' \
  --from-literal=DATABASE_URL='postgresql+psycopg2://policyledger:policyledger@postgres:5432/policyledger' \
  --dry-run=client -o yaml > k8s/02-secret.yaml

kubectl apply -f k8s/
kubectl rollout status deployment/policyledger-api -n policyledger

kubectl port-forward -n policyledger svc/policyledger-api 8001:8000
# in another terminal: curl http://localhost:8001/healthz
```

Tear it all down:

```bash
cd terraform
terraform destroy
```

Verified: ran the full cycle above from a completely destroyed state (`terraform destroy` → confirmed `docker ps` and `kind get clusters` showed nothing left → `terraform apply` again), and the app worked identically on the rebuilt cluster.

## Image size

| Build | Size |
|---|---|
| Single-stage (`pip install` + app code, one `FROM`) | 188MB |
| Multi-stage (this repo's `Dockerfile`) | 192MB |

Multi-stage is **not smaller** here, and I'm reporting that honestly rather than the number I expected. The reason: every dependency in `requirements.txt` (`psycopg2-binary` included) ships as a prebuilt wheel, so `pip install` never needed a C compiler or build headers in the first place — there was no build-time bloat for a second stage to strip out. Multi-stage still earns its place in this repo for a different reason: it's a clean boundary between "things needed to install packages" and "things needed to run the app," which is what let the runtime stage drop to a non-root user with nothing but the venv and app code in it. If a future dependency needs compiling from source (no wheel available), the size gap would show up then.

(These numbers are smaller than the ones recorded on Day 1 — 314MB/319MB — because the base image changed from `python:3.12-slim` to `python:3.12-alpine` on Day 3. See "what broke and how I fixed it" below for why.)

## Honesty notes (what's not enforced / not tested / simulated)

- **"Append-only" is enforced by omission, not by a database constraint.** No route or code path in this app updates or deletes `audit_log` rows. A Postgres role with `REVOKE UPDATE, DELETE` on that table would make this a DB-level guarantee instead of an application-level convention; that's not set up yet.
- **Actor identity is a trusted client-supplied header (`X-Actor`), not authentication.** There's no login system in this project. A real system would derive the actor from a verified session/token, not let the caller self-report it.
- **Tests run against SQLite, not Postgres.** This is faster and needs no daemon, but it means Postgres-specific behavior (e.g. `NUMERIC` precision edge cases) isn't exercised by the automated test suite — only by the manual `docker compose` + direct-`psql` check described below.
- **Base image versions aren't hash-pinned**, only tag-pinned (`python:3.12-slim`, `postgres:16-alpine`). Tags can move; a stricter setup would pin by digest.
- **The NetworkPolicy *is* enforced here — that's a correction, not a caveat.** The common wisdom (repeated in this repo's own [CLAUDE.md](CLAUDE.md)) is that kind's default CNI, kindnet, ignores NetworkPolicy resources entirely. That used to be true, but kindnet has since added real enforcement. Checked by hand on `kind v0.33.0`: a pod with no matching label got `nc: connection timed out` against `postgres:5432`, while a pod labeled `app=policyledger-api` connected immediately. Don't assume this holds on an older kind install — check it the same way (`kubectl run` a throwaway pod and try to connect) rather than trusting either claim blindly.
- **The Kubernetes Secret is base64, not encrypted.** `kubectl get secret policyledger-secret -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d` recovers the plaintext in one command. That's inherent to how Kubernetes Secrets work, not a mistake in this setup — a real deployment would add encryption-at-rest for the etcd store and/or pull values from an external secrets manager instead of trusting the base64 layer for confidentiality.
- **Postgres has no automated backup.** It's a single replica with a PVC; losing the node loses the data. Fine for a demo registry of fake policies, not fine for anything real.
- **`trivy config` in CI only fails the build on CRITICAL/HIGH findings, not LOW.** Six LOW findings remain by choice: both Deployments' containers should run as `runAsUser`/`runAsGroup` > 10000 per Kubernetes Pod Security Standards guidance (KSV-0020/KSV-0021). The API's UID 1000 is baked into the Dockerfile's non-root user; Postgres's UID 999 is the official `postgres:16-alpine` image's own built-in user and matches the PVC's `fsGroup`. Changing either risks breaking a currently-working setup (volume permissions, in Postgres's case) to satisfy a LOW-severity check — a real fintech would track this as a backlog item, not block a release on it, so that's what this repo does too.
- **CI's `trivy config` scan of `k8s/` never actually sees the real Secret manifest.** `k8s/02-secret.yaml` is gitignored and only ever exists on a developer's own machine (or, in CI, is generated fresh at deploy time in the smoke-test job with throwaway values) — so the committed `.example` template is all that's ever in the repo for `trivy config` to look at, and it's skipped anyway since `trivy` only scans `.yaml`/`.yml`/`.json` files by extension, not `.yaml.example`.
- **`aquasecurity/trivy-action` is pinned to an exact version tag (`0.36.0`), not `@master` or a floating major.** This project had a real supply-chain compromise in March 2026 — a credential-stealing commit was injected into every tag from `0.0.1` through `0.34.2` for about 12 hours. `0.36.0` post-dates that incident. Worth remembering as a general lesson: a security-scanning tool is itself part of your supply chain and needs the same pinning discipline as everything else, not an exemption because it "is" the security gate.

## What broke and how I fixed it

- **`Base.metadata.create_all()` was running at import time**, using the default (Postgres) `DATABASE_URL`. That meant even the test suite — which is supposed to use an in-memory SQLite database instead — tried to open a real Postgres connection during test collection and failed with `connection to server ... failed: Connection refused`. Fix: moved table creation into a FastAPI `lifespan` startup hook, so it only runs when the app actually starts, using whichever engine is configured at that point — and the test fixture patches that engine before startup runs.
- **Homebrew's `docker-desktop` cask install failed** while trying to symlink `docker-credential-osxkeychain` into `/usr/local/bin`, because that step needs `sudo` and an interactive terminal for the password prompt, which isn't available in this automated environment. Docker Desktop needs to be installed manually (`brew install --cask docker`, then approve the password prompt, then open Docker.app once to finish setup) before `docker compose up` can be run.
- **Homebrew's `terraform` formula doesn't exist anymore.** HashiCorp delisted it from homebrew-core after their 2023 license change (BSL). `brew tap hashicorp/tap && brew install hashicorp/tap/terraform` is the replacement, but that formula has no prebuilt bottle and needs a newer Xcode Command Line Tools than this machine had, so it tried to build from source and failed. Fix: downloaded the official prebuilt binary directly from `releases.hashicorp.com`, verified its SHA256 against HashiCorp's published checksums file before running it, and placed it on `PATH` by hand.
- **The API pods crashed once on every fresh Kubernetes deploy.** `docker-compose.yml` has `depends_on: condition: service_healthy`, so Postgres was always ready before the API started in Day 1. Kubernetes has no equivalent "wait for that other Deployment" primitive, so on a fresh `kubectl apply -f k8s/` the API pods raced Postgres, got `Connection refused`, and crashed before Kubernetes restarted them into a working state. Fixed with a `wait-for-postgres` init container (`k8s/06-api-deployment.yaml`) that blocks on `pg_isready` until Postgres actually answers.
- **Even after that fix, one pod still crashed — a different bug.** With the init container in place, both API pods correctly waited for Postgres, then both started at the same moment and both ran `Base.metadata.create_all()` (the same one-line schema setup from Day 1). Both checked "does the `policies` table exist?", both got "no" back, and both issued `CREATE TABLE` — the second one crashed on a duplicate-table error. This never showed up in Day 1 because `docker-compose.yml` only ever ran one API replica. Fixed in [`app/main.py`](app/main.py) with a Postgres advisory lock (`pg_advisory_lock`) around the create-tables step, so only one replica ever runs it; the other waits, then finds the tables already there. Confirmed fixed by deleting both pods simultaneously and checking restart counts (0 on both, previously 1 on one of them). The SQLite path the test suite uses skips the lock entirely — SQLite never has two processes hitting one database file at once here, and has no such function anyway.
- **`trivy image` found 3 real HIGH CVEs in `starlette`** (a FastAPI dependency, not something in `requirements.txt` directly) — `CVE-2024-47874`, `CVE-2026-48818`, `CVE-2026-54283`, all with fixes available in newer releases. `fastapi==0.115.0` (pinned since Day 1) only ever resolves to `starlette==0.38.6`, which predates all three fixes. Fix: bumped to `fastapi==0.141.1`, which resolves `starlette` to `1.7.0`. Re-ran the full test suite against the bump before touching anything else (all 5 passed) — a version bump that isn't verified against the tests is just a guess that it still works.
- **`trivy image` also found 44 HIGH CVEs in OS packages** (`util-linux`, `ncurses`, `perl-base`) baked into the `python:3.12-slim` base image, with no fix available from Debian yet as of 2026-09-24 — `trivy` reports their status as `affected` or `fix_deferred`, meaning there's nothing to bump to. Since `trivy image` is meant to *fail the CI build* on HIGH/CRITICAL, an unfixable HIGH finding would mean the gate is permanently red, which defeats the point of having it. I checked whether a different base image would do better before just suppressing the check: `python:3.12-slim-bookworm` (the previous Debian release) was actually worse (55 HIGH + 5 CRITICAL — older packages, not fewer CVEs), but `python:3.12-alpine` scanned **completely clean** (0 findings), and every dependency already ships a `musllinux` wheel, so there was no compiler-toolchain cost to switching. Fixed by changing the Dockerfile's base image to `python:3.12-alpine` (both stages), and swapping `groupadd`/`useradd` for alpine's `addgroup`/`adduser` in the non-root-user setup. Confirmed by rebuilding, re-running all 5 tests, redeploying to the local `kind` cluster, and confirming `/healthz` and `/policies` still respond correctly. Side benefit: the image also shrank from 319MB to 192MB.
- **A Postgres pod restarted once (self-healed) after applying the Day 3 `readOnlyRootFilesystem: true` hardening change.** Investigated rather than assumed-fine: `kubectl describe pod` showed a single `Liveness probe failed: /var/run/postgresql:5432 - no response` event, timed right when I'd just redeployed *both* Postgres and the API Deployments back-to-back on this laptop's local `kind` cluster. Reproduced in isolation by deleting the Postgres pod on its own and watching it: it went `Ready` in ~5 seconds, well inside the liveness probe's 15-second grace period, no restart. Conclusion: this was resource contention from redeploying two Deployments at once on a constrained local Docker Desktop VM, not a bug in the readonly-root-filesystem change itself — the liveness probe did exactly what it's supposed to do (catch a slow-starting container and let Kubernetes restart it) rather than silently leaving a broken pod in rotation. Left as-is rather than "fixed," since there was nothing wrong to fix.

## Repo layout

See [CLAUDE.md](CLAUDE.md) for the full target layout and 4-day plan.
