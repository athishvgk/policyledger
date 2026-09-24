# RUNBOOK

For a real on-call engineer landing here with an alert firing or a report that "the app is down." Assumes the standard local setup from the [README](README.md): a `kind` cluster named `policyledger`, everything in the `policyledger` namespace, monitoring in the `monitoring` namespace.

## First: is it actually down?

```bash
kubectl get pods -n policyledger
kubectl port-forward -n policyledger svc/policyledger-api 8001:8000 &
curl -i http://localhost:8001/healthz
```

If `/healthz` returns `200 {"status":"ok"}`, the app is up — the report was wrong, stale, or about something else (check the Grafana dashboard for error rate/latency before closing this out).

## The `PodRestarting` alert is firing

Check `http://localhost:9090/alerts` (see README's "Looking at monitoring" for the port-forward) to confirm it's real, then:

```bash
kubectl get pods -n policyledger -l app=policyledger-api
kubectl describe pod <pod-name> -n policyledger
```

Look at `describe pod`'s **Last State** block:

- **`Reason: OOMKilled`, `Exit Code: 137`** → memory limit too low, or the app is genuinely using more memory than expected. `kubectl logs --previous` will be **empty** — that's expected for an OOM kill, not a sign something else is wrong (the kernel kills the process before it can log anything; see [`INCIDENT-001.md`](INCIDENT-001.md)). Fix: raise the memory limit in [`k8s/06-api-deployment.yaml`](k8s/06-api-deployment.yaml) if the app's real usage grew, or investigate a memory leak if it shouldn't have.
- **`Reason: Error`, a stack trace in `kubectl logs --previous`** → a real code/config error. Read the trace. Common ones for this app: `Connection refused` (Postgres isn't up yet or is down — see below) or a bad `DATABASE_URL`/`POSTGRES_PASSWORD` (see Secret section below).
- **`CrashLoopBackOff` with increasing restart count, no clear reason in either place** → check `kubectl get events -n policyledger --sort-by=.lastTimestamp` for anything Kubernetes-level (image pull failure, scheduling failure, etc).

## `/healthz` times out or connection refused

```bash
kubectl get pods -n policyledger -l app=policyledger-api
```

If **0 pods are `Ready`**, the Service has nothing to route to — that's a full outage, not degraded capacity. Diagnose with the `PodRestarting` steps above. If some pods are `Ready`, this is likely a port-forward or local networking issue, not the app.

## Can the API reach Postgres?

```bash
kubectl get pods -n policyledger -l app=policyledger-postgres
kubectl logs -n policyledger -l app=policyledger-postgres --tail=50
```

If Postgres itself is down, the API's `wait-for-postgres` init container will keep the API pods stuck in `Init:0/1` (`kubectl describe pod` on an API pod will show this) rather than crash-looping — that's by design, not a bug. Fix Postgres first; the API pods will proceed on their own once it's reachable.

If Postgres is `Ready` but the API still can't connect, suspect the Secret (below) or the NetworkPolicy (`kubectl apply -f k8s/08-networkpolicy.yaml` if it was accidentally deleted — nothing else should be blocking `api → postgres:5432`).

## Wrong DB password / bad `DATABASE_URL`

Symptom: API pods crash-loop with `FATAL: password authentication failed` or similar in `kubectl logs --previous`, not empty like an OOM kill. Fix by regenerating the Secret with correct values (see README's "Running it on Kubernetes" for the exact command) and restarting the Deployment:

```bash
kubectl rollout restart deployment/policyledger-api -n policyledger
```

## High error rate (5xx) in Grafana

The dashboard's "5xx error rate" panel, or a manual query against Prometheus:

```
sum(rate(http_requests_total{status="5xx"}[5m])) / clamp_min(sum(rate(http_requests_total[5m])), 1e-9)
```

Check `kubectl logs -n policyledger -l app=policyledger-api --tail=100` for the actual stack traces behind the 5xxs — the dashboard tells you *that* it's happening, not *why*.

## HPA stuck at `<unknown>` targets

```bash
kubectl get hpa -n policyledger
kubectl top pods -n policyledger
```

If `kubectl top` also fails, `metrics-server` isn't running or isn't healthy:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server
```

See the README's honesty notes on `--kubelet-insecure-tls` if this is a fresh cluster and `metrics-server` itself won't start.

## When nothing here explains it

1. `kubectl get events -n policyledger --sort-by=.lastTimestamp` — Kubernetes-level events (scheduling, image pulls, probe failures) often explain what pod-level logs can't.
2. `kubectl describe deployment policyledger-api -n policyledger` — check `Conditions` for a stuck rollout.
3. Check the Grafana dashboard's "Pod restarts" panel and the Prometheus `/targets` page to confirm monitoring itself is healthy, not just the app.
4. If it's genuinely novel, that's a new incident — write it up the way [`INCIDENT-001.md`](INCIDENT-001.md) does: what happened, how it was found, how it was fixed, what would prevent it. Blameless.
