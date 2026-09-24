# HANDOFF: PolicyLedger platform project

Drop this file in the repo root (or rename it `CLAUDE.md`). It is everything you need to start; the full background guide is here: https://claude.ai/code/artifact/377553d8-3e9b-42fe-91cc-14abb0b3cac3

## 1. Why this project exists

Athish Govind (recent grad, strong in Python, SQL, React/Next.js, new to DevOps) is being considered by Jonathan for a **Platform Engineer** role at infineo (fully remote, DevOps/SRE flavored). Jonathan told him to decide whether this path is really his, and Athish wants to **show effort and real work** before applying. This repo is that proof.

infineo (https://infineo.ai) is a fintech that turns life-insurance policies into structured, tradable assets for credit unions and carriers (LifeNotes) and a blockchain token backed by cash surrender value (LifeCoin). The job posting asks for: Docker + Kubernetes, CI/CD (GitHub Actions/GitLab/Jenkins), Terraform/CloudFormation, monitoring (Prometheus/Grafana), secrets management, on-call/incident response, and fintech security/audit compliance.

## 2. Goal and hard constraints

Build **PolicyLedger**: a deliberately fake life-insurance policy registry, deployed the way a regulated fintech would. Target: **4 days**, free to run.

- **Synthetic data only.** Invented carriers, policies, cash surrender values. No real policy or customer data, ever.
- **Do not present it as infineo's system.** README must say it is "inspired by infineo's public description, not a copy of their system." No infineo logos or branding.
- **Athish must be able to explain every file.** Jonathan's advice: only claim what you can speak to. So teach as you build: before each step say in one or two plain sentences what it does and why; after each day, ask Athish to explain one piece back. Prefer small, readable code over clever code. Do not generate a black box.
- **No secrets in git.** Ever. Use env vars, Kubernetes Secrets (base64 is not encryption; say so in the README) and `.gitignore`.
- **Free by default.** Anything that costs money (real AWS) is an optional stretch and needs explicit approval from Athish first, with a budget alert created before `terraform apply` and `terraform destroy` the same day.

## 3. Stack (decided)

| Layer | Choice |
|---|---|
| App | FastAPI (Python) + Postgres |
| Containers | Docker, multi-stage, non-root; Docker Compose for local dev |
| Orchestration | Local `kind` cluster |
| IaC | Terraform with the `tehcyx/kind` provider (cluster) + Helm provider (monitoring). Not cloud. |
| CI/CD | GitHub Actions, images to GHCR tagged with commit SHA |
| Security gates | `gitleaks` (secrets), `trivy image` (fail on HIGH/CRITICAL), `trivy config` (Terraform + K8s manifests) |
| Monitoring | `kube-prometheus-stack` via Helm (Prometheus + Grafana), one alert |
| Not doing | Argo CD (skipped to fit 4 days), EKS/real cloud (optional stretch only) |

## 3a. Environment gotchas to check first

- Machine is a MacBook Air. Run `uname -m`. If `arm64`, use image tags that support arm64 (`python:3.12-slim` and `postgres` do) and expect CI (amd64) and local (arm64) images to differ.
- `kind` runs inside Docker Desktop. Set Docker Desktop resources to at least 4 CPUs and 6 GB RAM if the laptop allows. `kube-prometheus-stack` is heavy; if the laptop struggles, reduce replicas/retention or use a lighter Prometheus + Grafana install.
- Install: Docker Desktop, `kubectl`, `kind`, `helm`, `terraform`, `gitleaks`, `trivy`. Verify each with `--version` before starting.
- Version pins below were checked on 2026-09-24. Re-check the latest majors before committing: `actions/checkout`, `actions/setup-python`, `docker/setup-buildx-action` (v4), `docker/login-action` (v4), `docker/build-push-action` (v7), kind provider (0.11.0 at last check).

## 4. Repo layout (target)

```
policyledger/
  app/                  # FastAPI service, tests/
  Dockerfile            # multi-stage, non-root
  docker-compose.yml    # api + postgres
  seed/seed.py          # inserts 10-20 fake policies
  k8s/                  # namespace, deployment, service, configmap, secret (template), networkpolicy, hpa
  terraform/            # kind cluster + helm_release for monitoring
  .github/workflows/ci.yml
  README.md             # architecture diagram, what each piece proves, "what broke and how I fixed it"
  RUNBOOK.md            # "if the app is down, check X then Y"
  INCIDENT-001.md       # blameless incident note from the day-4 break-it exercise
  HANDOFF.md            # this file
```

## 5. Plan with acceptance criteria

### Day 1: service + hardened container

- FastAPI endpoints: `GET /healthz`, `GET /policies`, `POST /policies`, `PATCH /policies/{id}`.
- Policy fields: `id`, `carrier`, `cash_surrender_value`, `status`, `updated_at`.
- Every create/update also inserts a row into an **append-only** `audit_log` table (who/what/when/before/after). No update or delete path for `audit_log` in the app.
- Multi-stage Dockerfile, non-root user, pinned base image, `.dockerignore`. Record image size before and after multi-stage in the README.
- Done when: `docker compose up` runs API + Postgres, seed script loads fake data, tests pass, audit rows appear on writes.

### Day 2: Terraform + Kubernetes

- Terraform: `kind_cluster`, then `helm_release` for `kube-prometheus-stack`. Variables for cluster name; state kept out of git (`.gitignore`), commit `.terraform.lock.hcl`.
- K8s manifests: namespace, Deployment (2 replicas), Service, ConfigMap, Secret for DB credentials (commit a template, not real values), resource requests/limits, readiness + liveness probes on `/healthz`, `securityContext` (`runAsNonRoot`, `readOnlyRootFilesystem`, drop capabilities), NetworkPolicy so only the API pod can reach Postgres.
- **Gotcha:** a NetworkPolicy does nothing unless the cluster's CNI enforces it. Check whether the kind setup does. If not, install Calico or Cilium, or state honestly in the README that it is not enforced locally.
- Done when: `terraform apply` builds the cluster from scratch, `kubectl apply -f k8s/` runs the app, `kubectl port-forward` reaches it, and `terraform destroy` cleanly removes everything.

### Day 3: CI/CD with security gates

- GitHub Actions on push and pull request: setup Python, install, tests; `gitleaks`; `terraform fmt -check` and `terraform validate`; `trivy config` on `terraform/` and `k8s/`; build image with Buildx and layer cache (`cache-from`/`cache-to: type=gha`); `trivy image` failing on HIGH/CRITICAL; on `main` only, push to GHCR tagged with the commit SHA (image names must be lowercase); a job that spins up a throwaway `kind` cluster, deploys, and curls `/healthz` as a smoke test.
- Done when: a green run on `main`, a deliberately failing run (for example an unpinned vulnerable base image or a fake committed key) that the gates correctly block, and both runs referenced in the README.

### Day 4: observability, incident, polish

- Grafana dashboard (requests, error rate, pod restarts) and one Prometheus alert rule (pod restarts or 5xx rate).
- Break something on purpose (bad image tag, wrong DB password, memory limit too low). Diagnose with `kubectl get/describe/logs`. Write `INCIDENT-001.md`: what happened, how it was found, how it was fixed, what prevents it. Blameless tone.
- HPA plus a short load test showing pods scale up (optional if time is short).
- README with architecture diagram, "what each piece proves", "what broke and how I fixed it". `RUNBOOK.md`. A 2 to 3 minute screen recording.
- Done when: a stranger can clone the repo and reproduce it from the README in under 30 minutes.

### Optional stretches (only after all four days are done)

- Run Foundry's `anvil` (local Ethereum dev node) as a container and alert when it stops producing blocks. infineo tokenizes on-chain but the pages read do not say which chain, so treat this as a stand-in and a question to ask Jonathan.
- Terraform on real AWS (small VPC, ECR, S3, least-privilege IAM). New accounts get $100 in credits plus up to $100 more for 6 months. EKS has no free tier ($0.10 per cluster per hour for the control plane, plus nodes and other charges); only run it for hours and destroy it the same day. Check which services credits cover before relying on them.

## 6. Working agreements for Claude Code

1. Start by reading this file, then `uname -m` and the tool versions, then propose the Day 1 plan and wait for Athish's go-ahead.
2. Work in small commits with clear messages. One concern per commit.
3. Explain-then-do: one or two plain sentences before each new tool or concept (Docker, kind, Terraform state, NetworkPolicy, and so on). Athish is new to operations, so use simple analogies where they help.
4. End each day with a 3-question check where Athish explains something he built. If he cannot, slow down and re-explain rather than moving on.
5. Never run `terraform apply` against a real cloud, spend money, or push to a remote without explicit approval.
6. When something breaks, do not silently fix it. Show the error, explain the cause, then fix it. Add it to the README's "what broke and how I fixed it" section; real failures are the most convincing part of this project.
7. Keep the README honest: list what is not enforced, not tested, or simulated.

## 7. Questions worth asking Jonathan (not blockers)

- Which cloud does infineo run on (AWS, Azure, GCP)?
- Which blockchain does LifeCoin use, and how does the team monitor it?
- How does the team handle secrets and audit evidence for compliance?

## 8. Definition of done

Public GitHub repo, green CI on `main`, reproducible from the README, `INCIDENT-001.md` written, short demo recording, and Athish can explain every file out loud. Then he emails Jonathan the repo link, a 2 to 3 sentence summary, and one real question.
