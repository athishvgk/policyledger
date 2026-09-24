# INCIDENT-001: api pods OOMKilled after a memory limit set too low

This is a deliberate incident, staged on purpose as part of Day 4 of this
project, not a real production outage. The point is to practice diagnosing
a failure with the same tools and evidence a real on-call engineer would
use, and to prove the alert built earlier in Day 4 actually fires instead
of just parsing.

**Status:** resolved. **Severity:** none (local dev cluster, synthetic
data, no user impact). **Duration:** ~1 minute (19:12:26 UTC → 19:14:00
UTC, 2026-09-24).

## What happened

The `api` container's memory limit was changed from `256Mi` to `16Mi`
directly on the live Deployment (`kubectl patch`, not committed to git --
see "Blast radius" below for why). `16Mi` is not enough for a Python
process to even finish starting up. Kubernetes' `readOnlyRootFilesystem`
and other Day 2/3 hardening had nothing to do with this: this was a plain
resource-limit misconfiguration, the kind that's easy to introduce by
hand-editing a manifest or copy-pasting a value from a different, smaller
service.

## How it was found

Watching `kubectl get pods -n policyledger -l app=policyledger-api -w`
immediately after the patch showed the new pod cycling:

```
NAME                                READY   STATUS      RESTARTS   AGE
policyledger-api-6cbc7d948f-brh5g   0/1     OOMKilled   0          5s
policyledger-api-6cbc7d948f-brh5g   0/1     Running     1 (2s ago)   5s
policyledger-api-6cbc7d948f-brh5g   0/1     OOMKilled   1 (3s ago)   6s
policyledger-api-6cbc7d948f-brh5g   0/1     CrashLoopBackOff   2 (1s ago)   20s
```

`kubectl describe pod` on the crashing pod gave the actual diagnosis:

```
State:          Waiting
  Reason:       CrashLoopBackOff
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
Limits:
  memory:  16Mi
```

`Exit Code: 137` is `128 + SIGKILL(9)`, always worth recognizing on sight --
it means something killed the process outright, not the process exiting
on its own.

**The one genuinely useful lesson here:** `kubectl logs --previous` on the
crashed container came back completely empty. An OOM kill is enforced by
the Linux kernel's cgroup accounting, which kills the process the instant
it crosses the memory limit -- there is no chance for the process to log
an error, catch an exception, or print anything on its way out. This is a
different failure signature than a config error (wrong DB password, bad
image tag): those show up as a clear stack trace or connection error in
the logs. An OOM kill shows up as *silence* in the logs and `OOMKilled` in
`describe pod`. If you only check `kubectl logs`, this incident looks like
nothing happened.

Separately, the `PodRestarting` alert from earlier in Day 4
(`k8s/10-prometheus-rule.yaml`) was confirmed firing for real, not just
theoretically correct, by querying Prometheus's own rules API mid-incident:

```json
{
  "state": "firing",
  "name": "PodRestarting",
  "alerts": [{
    "labels": {"pod": "policyledger-api-6cbc7d948f-brh5g", "container": "api", ...},
    "state": "firing"
  }]
}
```

## How it was fixed

Patched the memory limit back to its working value (`256Mi` limit / `128Mi`
request -- the same values in `k8s/06-api-deployment.yaml`, which was never
changed):

```bash
kubectl patch deployment policyledger-api -n policyledger --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"256Mi"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"128Mi"}
]'
```

Kubernetes' default rolling-update strategy meant the two already-healthy
pods were never touched during the ~90 seconds this was broken -- only the
one new pod (created by the bad patch itself) crash-looped. `/healthz`
was confirmed responding through the real Service immediately after the
rollout finished.

## What prevents this

- **Nothing in this project statically prevents an unreasonably low
  memory limit from being applied.** `trivy config` (Day 3's CI gate)
  checks that limits *exist* (KSV-0011), not that their *values* are
  sane -- `16Mi` would have passed that gate cleanly. This is a real,
  honestly-stated gap, not something quietly worked around.
- The `PodRestarting` alert (Day 4) is what actually would have surfaced
  this in a real environment, and it did: it went from `inactive` to
  `firing` within one Prometheus evaluation cycle (30s) of the first
  restart, with `kubectl describe`/`kubectl logs --previous` commands
  built into its annotation so the next person doesn't have to guess
  where to look.
- The readiness probe (not the liveness probe) is what actually protects
  traffic here: a crash-looping pod never becomes `Ready`, so the Service
  never routes to it. With 2 replicas, one bad pod costs capacity, not an
  outage.

## Blast radius / why this was staged the way it was

This incident was reproduced by `kubectl patch`-ing the *live* Deployment
directly, not by committing a broken `k8s/06-api-deployment.yaml` to git.
That was a deliberate choice: it reproduces a real category of incident
(someone runs an imperative `kubectl edit`/`kubectl patch` against a
running cluster, drifting it from what's in git) without ever putting a
known-broken manifest into version control, even briefly. `git log` for
`k8s/06-api-deployment.yaml` has no incident-related commit, because
nothing about that file was ever actually wrong.
