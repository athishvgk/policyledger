# PolicyLedger

A synthetic life-insurance policy registry, built and deployed the way a regulated fintech would: hardened containers, Kubernetes, Terraform, CI security gates, and monitoring.

**This project is inspired by infineo's public description of what they do — turning life-insurance policies into structured, tradable assets — and is not a copy of their system.** No infineo logos, branding, or real data are used anywhere here. All carriers, policies, and cash surrender values in this repo are invented.

Why this repo exists: I'm being considered for a Platform Engineer role and wanted to show real, explainable infrastructure work rather than just claim I know the tools. Every file here I can walk through and explain out loud, including what broke while building it.

## Status

Day 4 of 4 (observability, incident, polish) is done: Prometheus scrapes the API's own `/metrics`, one alert rule watches for pod restarts, a Grafana dashboard shows request rate/error rate/restarts, a real incident was staged and diagnosed ([`INCIDENT-001.md`](INCIDENT-001.md)), and an HPA was verified scaling real pods under real load. See [CLAUDE.md](CLAUDE.md) for the full day-by-day plan and acceptance criteria, and [RUNBOOK.md](RUNBOOK.md) for "the app is down, now what."

## What's here so far

- **`app/`** — a FastAPI service backed by Postgres. Endpoints: `GET /healthz`, `GET /policies`, `POST /policies`, `PATCH /policies/{id}`.
- **Append-only audit log** — every create/update also writes a row to `audit_log` (who via an `X-Actor` header, what changed, before/after snapshots, when). There is no update or delete code path for that table anywhere in the app — "append-only" here means "nothing in this codebase can rewrite history," not a database-level guarantee (see Honesty notes).
- **`Dockerfile`** — multi-stage build, runs as a non-root user, pinned base image (`python:3.12-slim`), dependencies installed into an isolated virtualenv in a separate build stage so the final image doesn't carry build tools.
- **`docker-compose.yml`** — runs the API and Postgres together locally.
- **`seed/seed.py`** — posts ~15 fake policies to a running API so there's something to look at.
- **`tests/`** — pytest suite (5 tests) covering the endpoints and, directly, that audit rows actually land in the database on writes. Tests run against SQLite in-memory, not Postgres, so they don't require Docker (see Honesty notes).
- **`terraform/`** — provisions a local `kind` (Kubernetes-in-Docker) cluster and installs `kube-prometheus-stack` into it via the `helm` provider. Nothing here touches any cloud account; `apply`/`destroy` only create and remove local Docker containers.
- **`k8s/`** — manifests for the app itself: namespace, Postgres (Deployment + PVC + Service), the API (Deployment, 2 replicas, hardened `securityContext`, resource limits, `/healthz` probes), a Secret template (see below), a NetworkPolicy restricting Postgres to the API pod, a `ServiceMonitor` + `PrometheusRule` for observability, a Grafana dashboard ConfigMap, and an HPA.
- **`.github/workflows/ci.yml`** — five jobs on every push/PR: unit tests, a `gitleaks` secret scan, `terraform fmt`/`validate`, a `trivy config` scan of `terraform/` and `k8s/`, and a build that's scanned with `trivy image` before anything is pushed. On `main` only, the scanned image is pushed to GHCR tagged with the commit SHA, and a separate job spins up a throwaway `kind` cluster in the runner, deploys the app to it, and curls `/healthz` for real — not just "tests passed." These gates aren't theoretical — see "what broke and how I fixed it" below for three real runs the gates genuinely blocked, plus the first fully green run: [failing run (bad action version pin)](https://github.com/athishvgk/policyledger/actions/runs/36078317116), [failing run (real starlette CVEs)](https://github.com/athishvgk/policyledger/actions/runs/36078402575), [failing run (smoke-test job bugs)](https://github.com/athishvgk/policyledger/actions/runs/36078985708), [green run](https://github.com/athishvgk/policyledger/actions/runs/36079580766).
- **Observability** — `Instrumentator().instrument(app).expose(app)` in [`app/main.py`](app/main.py) exposes `GET /metrics` (`prometheus-fastapi-instrumentator`). [`k8s/09-servicemonitor.yaml`](k8s/09-servicemonitor.yaml) tells the `kube-prometheus-stack` Prometheus to scrape it every 15s. [`k8s/10-prometheus-rule.yaml`](k8s/10-prometheus-rule.yaml) is one alert, `PodRestarting`, that fires on `increase(kube_pod_container_status_restarts_total[15m]) > 0`. [`k8s/dashboards/grafana-dashboard.json`](k8s/dashboards/grafana-dashboard.json) (loaded into the cluster via [`k8s/11-grafana-dashboard-configmap.yaml`](k8s/11-grafana-dashboard-configmap.yaml), auto-imported by Grafana's sidecar) shows request rate by status, 5xx error rate, and pod restarts.
- **HPA** — [`k8s/12-hpa.yaml`](k8s/12-hpa.yaml) scales the API Deployment 2→5 replicas on CPU. It needs `metrics-server` (added to `terraform/main.tf`) to read real usage — without it an HPA just shows `<unknown>` forever.
- **`INCIDENT-001.md`** — a deliberately staged incident (memory limit set too low → `OOMKilled`), diagnosed the way a real on-call engineer would, written up blameless.

## Architecture

```
                      ┌─────────────────────────────────────────────┐
                      │              kind cluster ("policyledger")  │
                      │                                              │
  developer  ──apply──▶  Terraform: kind_cluster + 2 helm_release    │
  (terraform)          │  (kube-prometheus-stack, metrics-server)    │
                      │                                              │
                      │  ┌── namespace: policyledger ─────────────┐ │
                      │  │                                         │ │
  kubectl apply  ─────▶  │  Deployment (2-5 pods, HPA-scaled) ──┐  │ │
  -f k8s/              │  │  policyledger-api  /healthz /metrics │  │ │
                      │  │       │            └──────┬──────────┘  │ │
                      │  │  NetworkPolicy            │             │ │
                      │  │  (api → postgres only)    │ scraped by  │ │
                      │  │       ▼                   ▼             │ │
                      │  │  Deployment: postgres   ServiceMonitor  │ │
                      │  │  (1 pod, PVC)                           │ │
                      │  └─────────────────────────────────────────┘ │
                      │                            │                 │
                      │  ┌── namespace: monitoring ▼──────────────┐ │
                      │  │  Prometheus  ──rule──▶ PodRestarting    │ │
                      │  │       │        alert                    │ │
                      │  │       └──datasource──▶ Grafana          │ │
                      │  │                         (PolicyLedger    │ │
                      │  │                          dashboard)      │ │
                      │  └─────────────────────────────────────────┘ │
                      └─────────────────────────────────────────────┘
```

Everything above runs as Docker containers on one laptop. Nothing here talks to a real cloud account.

## What each piece proves

| Piece | Proves |
|---|---|
| Multi-stage, non-root `Dockerfile` | Understand container hardening, not just "it runs" |
| Append-only `audit_log` | Can design for auditability, a real fintech/compliance requirement |
| Terraform (`kind_cluster` + 2x `helm_release`) | Can express infrastructure as versioned, reproducible code, not clicked-together state |
| `securityContext`, resource limits, probes, NetworkPolicy | Know the Kubernetes hardening checklist, and *checked* the NetworkPolicy actually enforces (see Honesty notes) rather than assuming |
| `gitleaks` + `trivy config` + `trivy image` in CI | Understand shift-left security gates, and that they have to actually be able to fail the build (see the deliberately-failing-run in the CI history) |
| `ServiceMonitor` / `PrometheusRule` / Grafana dashboard | Can wire up real monitoring, not just install a chart — verified against live Prometheus/Grafana APIs, not just "manifest applied" |
| `INCIDENT-001.md` | Can diagnose a real failure with `kubectl get/describe/logs`, distinguish an OOM kill from a config error, and write it up without blame |
| HPA + metrics-server, verified with a load test | Know that autoscaling needs a metrics source to actually work, and proved it scales under real load rather than trusting the YAML |

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

## Looking at monitoring (Prometheus + Grafana)

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
# admin password:
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

Open `http://localhost:3000`, log in as `admin`, and the "PolicyLedger" dashboard is already there (Grafana's sidecar auto-imports any ConfigMap labeled `grafana_dashboard: "1"` — no manual import step). Prometheus's own UI, for checking scrape targets or firing alerts directly:

```bash
kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090
# http://localhost:9090/targets and http://localhost:9090/alerts
```

## Watching the HPA scale under load

```bash
kubectl port-forward -n policyledger svc/policyledger-api 8001:8000 &
kubectl get hpa -n policyledger -w   # in another terminal

# generate load against a real DB-backed endpoint
for w in $(seq 1 25); do
  ( end=$((SECONDS+150)); while [ $SECONDS -lt $end ]; do curl -s -o /dev/null http://localhost:8001/policies; done ) &
done
```

Verified: 25 concurrent workers for 150s pushed CPU from 5% to 126% of the 50%-utilization target; the HPA scaled the Deployment 2 → 4 → 5 replicas within about a minute, then held at 5/52% until the load tapered off. This needs `metrics-server` (`terraform/main.tf`) — without it the HPA shows `<unknown>` targets forever, since there's nowhere for it to read live CPU/memory from.

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
- **Alertmanager is disabled** (`terraform/main.tf`) — there's nowhere real to route a notification (no Slack/email/PagerDuty for a solo demo project). A fired alert is only ever inspected in Prometheus's own `/alerts` UI, not pushed anywhere. A real deployment would wire this to an actual on-call channel.
- **`trivy config` checks that resource limits *exist*, not that their values are sane.** [`INCIDENT-001.md`](INCIDENT-001.md) proves this the hard way: a `16Mi` memory limit (enough to guarantee an immediate `OOMKilled`) passes `trivy config`'s KSV-0011 check cleanly, because the check is "is a limit set," not "is this a reasonable number." Nothing in this repo statically catches that class of mistake.
- **`metrics-server` runs with `--kubelet-insecure-tls`, which is a kind-local-dev workaround, not something to carry into a real cluster.** kind's kubelet serves its metrics over a self-signed certificate that isn't part of any CA `metrics-server` trusts by default. A real cluster would have `metrics-server` verify the kubelet's certificate properly instead of skipping verification.

## What broke and how I fixed it

- **`Base.metadata.create_all()` was running at import time**, using the default (Postgres) `DATABASE_URL`. That meant even the test suite — which is supposed to use an in-memory SQLite database instead — tried to open a real Postgres connection during test collection and failed with `connection to server ... failed: Connection refused`. Fix: moved table creation into a FastAPI `lifespan` startup hook, so it only runs when the app actually starts, using whichever engine is configured at that point — and the test fixture patches that engine before startup runs.
- **Homebrew's `docker-desktop` cask install failed** while trying to symlink `docker-credential-osxkeychain` into `/usr/local/bin`, because that step needs `sudo` and an interactive terminal for the password prompt, which isn't available in this automated environment. Docker Desktop needs to be installed manually (`brew install --cask docker`, then approve the password prompt, then open Docker.app once to finish setup) before `docker compose up` can be run.
- **Homebrew's `terraform` formula doesn't exist anymore.** HashiCorp delisted it from homebrew-core after their 2023 license change (BSL). `brew tap hashicorp/tap && brew install hashicorp/tap/terraform` is the replacement, but that formula has no prebuilt bottle and needs a newer Xcode Command Line Tools than this machine had, so it tried to build from source and failed. Fix: downloaded the official prebuilt binary directly from `releases.hashicorp.com`, verified its SHA256 against HashiCorp's published checksums file before running it, and placed it on `PATH` by hand.
- **The API pods crashed once on every fresh Kubernetes deploy.** `docker-compose.yml` has `depends_on: condition: service_healthy`, so Postgres was always ready before the API started in Day 1. Kubernetes has no equivalent "wait for that other Deployment" primitive, so on a fresh `kubectl apply -f k8s/` the API pods raced Postgres, got `Connection refused`, and crashed before Kubernetes restarted them into a working state. Fixed with a `wait-for-postgres` init container (`k8s/06-api-deployment.yaml`) that blocks on `pg_isready` until Postgres actually answers.
- **Even after that fix, one pod still crashed — a different bug.** With the init container in place, both API pods correctly waited for Postgres, then both started at the same moment and both ran `Base.metadata.create_all()` (the same one-line schema setup from Day 1). Both checked "does the `policies` table exist?", both got "no" back, and both issued `CREATE TABLE` — the second one crashed on a duplicate-table error. This never showed up in Day 1 because `docker-compose.yml` only ever ran one API replica. Fixed in [`app/main.py`](app/main.py) with a Postgres advisory lock (`pg_advisory_lock`) around the create-tables step, so only one replica ever runs it; the other waits, then finds the tables already there. Confirmed fixed by deleting both pods simultaneously and checking restart counts (0 on both, previously 1 on one of them). The SQLite path the test suite uses skips the lock entirely — SQLite never has two processes hitting one database file at once here, and has no such function anyway.
- **`trivy image` found 3 real HIGH CVEs in `starlette`** (a FastAPI dependency, not something in `requirements.txt` directly) — `CVE-2024-47874`, `CVE-2026-48818`, `CVE-2026-54283`, all with fixes available in newer releases. `fastapi==0.115.0` (pinned since Day 1) only ever resolves to `starlette==0.38.6`, which predates all three fixes. Fix: bumped to `fastapi==0.141.1`, which resolves `starlette` to `1.7.0`. Re-ran the full test suite against the bump before touching anything else (all 5 passed) — a version bump that isn't verified against the tests is just a guess that it still works.
- **`trivy image` also found 44 HIGH CVEs in OS packages** (`util-linux`, `ncurses`, `perl-base`) baked into the `python:3.12-slim` base image, with no fix available from Debian yet as of 2026-09-24 — `trivy` reports their status as `affected` or `fix_deferred`, meaning there's nothing to bump to. Since `trivy image` is meant to *fail the CI build* on HIGH/CRITICAL, an unfixable HIGH finding would mean the gate is permanently red, which defeats the point of having it. I checked whether a different base image would do better before just suppressing the check: `python:3.12-slim-bookworm` (the previous Debian release) was actually worse (55 HIGH + 5 CRITICAL — older packages, not fewer CVEs), but `python:3.12-alpine` scanned **completely clean** (0 findings), and every dependency already ships a `musllinux` wheel, so there was no compiler-toolchain cost to switching. Fixed by changing the Dockerfile's base image to `python:3.12-alpine` (both stages), and swapping `groupadd`/`useradd` for alpine's `addgroup`/`adduser` in the non-root-user setup. Confirmed by rebuilding, re-running all 5 tests, redeploying to the local `kind` cluster, and confirming `/healthz` and `/policies` still respond correctly. Side benefit: the image also shrank from 319MB to 192MB.
- **A Postgres pod restarted once (self-healed) after applying the Day 3 `readOnlyRootFilesystem: true` hardening change.** Investigated rather than assumed-fine: `kubectl describe pod` showed a single `Liveness probe failed: /var/run/postgresql:5432 - no response` event, timed right when I'd just redeployed *both* Postgres and the API Deployments back-to-back on this laptop's local `kind` cluster. Reproduced in isolation by deleting the Postgres pod on its own and watching it: it went `Ready` in ~5 seconds, well inside the liveness probe's 15-second grace period, no restart. Conclusion: this was resource contention from redeploying two Deployments at once on a constrained local Docker Desktop VM, not a bug in the readonly-root-filesystem change itself — the liveness probe did exactly what it's supposed to do (catch a slow-starting container and let Kubernetes restart it) rather than silently leaving a broken pod in rotation. Left as-is rather than "fixed," since there was nothing wrong to fix.
- **The first CI run on GitHub failed immediately** ([run](https://github.com/athishvgk/policyledger/actions/runs/36078317116)) with `Unable to resolve action aquasecurity/trivy-action@0.36.0, unable to find version 0.36.0`. The tag exists on GitHub, but it's `v0.36.0` — the workflow's `uses:` lines dropped the `v` prefix while the comment right above them had it correct. A one-character typo, not a real supply-chain or vulnerability issue. Fixed in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) by adding the missing `v` to all three `trivy-action` references, verified by re-running CI.
- **The second CI run failed `trivy image scan`** ([run](https://github.com/athishvgk/policyledger/actions/runs/36078402575)) **on the exact `starlette` CVEs the earlier fix above (bumping to `fastapi==0.141.1`) was supposed to have already resolved** — this time `CVE-2026-48818` and `CVE-2026-54283`, still HIGH, still unfixed. Root cause: `requirements.txt` never pinned `starlette` itself, only `fastapi` (which just requires `starlette>=0.46.0` — any version above that satisfies it). The original fix worked by coincidence: at the time, nothing else in the dependency tree constrained `starlette`, so pip's resolver happened to land on a fixed `1.7.0`. A later, unrelated commit adding `prometheus-fastapi-instrumentator==7.0.0` (which requires `starlette<1.0.0`) silently pulled `starlette` back down to a vulnerable `0.52.1` on the next fresh install — nobody noticed locally because a developer's existing virtualenv doesn't get its transitive dependencies re-resolved on every `pip install`, but GitHub Actions builds from a clean environment every run and caught it immediately. Fixed by pinning `starlette==1.7.0` directly in [`requirements.txt`](requirements.txt) and bumping `prometheus-fastapi-instrumentator` to `8.1.0` (the first release line that allows `starlette>=1.0.0`). Verified before pushing, not just hoped: ran the full test suite against the new dependency set (5 passed), then built the actual Docker image locally and ran `trivy image --severity CRITICAL,HIGH` against it directly, confirming 0 findings, before committing. Lesson: fixing a CVE in a *transitive* dependency by bumping the *direct* one that pulls it in doesn't stick unless the transitive dependency is also pinned — otherwise the next unrelated dependency change can silently re-open the same hole.
- **The third CI run** ([run](https://github.com/athishvgk/policyledger/actions/runs/36078985708)) **got past the trivy image scan (confirming the starlette fix above genuinely worked) but failed in a brand-new job: the smoke test that deploys to a throwaway `kind` cluster and curls `/healthz`.** Two separate, unrelated bugs, both real: (1) `kubectl apply -f k8s/` tried to parse [`k8s/grafana-dashboard.json`](k8s/dashboards/grafana-dashboard.json) as a Kubernetes manifest and failed with `error validating data: [apiVersion not set, kind not set]` — that file is plain dashboard JSON, source data for the `kubectl create configmap --from-file=...` command documented in [`k8s/11-grafana-dashboard-configmap.yaml`](k8s/11-grafana-dashboard-configmap.yaml), never meant to be applied directly, but it lived right inside `k8s/` so the directory-wide apply swept it up anyway. (2) `k8s/09-servicemonitor.yaml` and `k8s/10-prometheus-rule.yaml` failed with `no matches for kind "ServiceMonitor"/"PrometheusRule" ... ensure CRDs are installed first` — those CRDs only exist once the Prometheus Operator is installed, which happens on the real cluster via `terraform/main.tf`'s `helm_release` for `kube-prometheus-stack`, but the CI smoke-test cluster is spun up bare (just `helm/kind-action`, no chart) since it only needs to prove the app itself deploys and serves `/healthz`. Fixed (1) by moving the JSON file to [`k8s/dashboards/grafana-dashboard.json`](k8s/dashboards/grafana-dashboard.json) — `kubectl apply -f k8s/` is not recursive, so a subdirectory is invisible to it. Fixed (2) in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) by having the smoke-test job apply each `k8s/*.yaml` file individually, explicitly skipping the ServiceMonitor and PrometheusRule manifests, rather than installing the whole Prometheus Operator just for a `/healthz` check.
- **The Grafana dashboard's 5xx-rate query assumed exact status codes (`status=~"5.."`) and silently matched nothing.** `prometheus-fastapi-instrumentator`'s default `http_requests_total` metric groups the `status` label into classes (`"2xx"`, `"4xx"`, `"5xx"`), not exact codes like `"404"` — found by reading the library's own source and confirming with a live Prometheus query. Fixed by changing the regex to an exact match, `status="5xx"`.
- **A deliberate `16Mi` memory-limit patch produced silent pods** — `kubectl logs --previous` on the `OOMKilled` container came back completely empty, because a cgroup OOM kill gives the process no chance to log anything on the way out. Full writeup, including confirming the `PodRestarting` alert actually transitioned to `firing` mid-incident, is in [`INCIDENT-001.md`](INCIDENT-001.md).

## Repo layout

See [CLAUDE.md](CLAUDE.md) for the full target layout and 4-day plan.
