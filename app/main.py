import json
from contextlib import asynccontextmanager
from typing import List

from fastapi import Depends, FastAPI, Header, HTTPException
from prometheus_fastapi_instrumentator import Instrumentator
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.database import Base, engine, get_db
from app.models import AuditLog, Policy
from app.schemas import PolicyCreate, PolicyOut, PolicyUpdate

# Arbitrary fixed id for a Postgres advisory lock -- see the race-condition
# note in lifespan() below. Any int64 works; it just has to be the same
# constant every time this app starts.
_SCHEMA_LOCK_ID = 727271


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Creates tables if they're missing. A real system would use migrations
    # (e.g. Alembic) so schema changes are reviewable and reversible; this is
    # a synthetic registry, so a one-line create_all is enough and keeps
    # every file easy to explain. Runs at startup (not import time) so tests
    # can swap in a different engine first.
    #
    # With 2 replicas (Day 2), both pods run this at once: both check
    # "does `policies` exist?", both see no, both issue CREATE TABLE, and
    # one crashes on a duplicate-table error. A Postgres advisory lock
    # serializes that check-then-create so only one replica ever does it.
    # SQLite (used by the test suite) has no such thing and never runs more
    # than one process against one database, so it skips straight to
    # create_all.
    if engine.dialect.name == "postgresql":
        with engine.begin() as conn:
            conn.execute(text("SELECT pg_advisory_lock(:lock_id)"), {"lock_id": _SCHEMA_LOCK_ID})
            Base.metadata.create_all(bind=conn)
            conn.execute(text("SELECT pg_advisory_unlock(:lock_id)"), {"lock_id": _SCHEMA_LOCK_ID})
    else:
        Base.metadata.create_all(bind=engine)
    yield


app = FastAPI(title="PolicyLedger", lifespan=lifespan)

# Adds a GET /metrics endpoint in Prometheus's text format: request counts
# and latency, labeled by path/method/status code. This alone doesn't get
# scraped by anything -- that's what the ServiceMonitor in
# k8s/09-servicemonitor.yaml is for.
Instrumentator().instrument(app).expose(app)


def _snapshot(policy: Policy) -> dict:
    """JSON-safe copy of a policy row, used as the audit log's before/after."""
    return {
        "id": policy.id,
        "carrier": policy.carrier,
        "cash_surrender_value": str(policy.cash_surrender_value),
        "status": policy.status,
    }


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/policies", response_model=List[PolicyOut])
def list_policies(db: Session = Depends(get_db)):
    return db.query(Policy).order_by(Policy.id).all()


@app.post("/policies", response_model=PolicyOut, status_code=201)
def create_policy(
    payload: PolicyCreate,
    db: Session = Depends(get_db),
    x_actor: str = Header(default="unknown"),
):
    policy = Policy(**payload.model_dump())
    db.add(policy)
    db.flush()  # assigns policy.id without committing yet, so the audit
    # row below can reference it in the same transaction

    db.add(
        AuditLog(
            policy_id=policy.id,
            action="create",
            actor=x_actor,
            before=None,
            after=json.dumps(_snapshot(policy)),
        )
    )
    db.commit()
    db.refresh(policy)
    return policy


@app.patch("/policies/{policy_id}", response_model=PolicyOut)
def update_policy(
    policy_id: int,
    payload: PolicyUpdate,
    db: Session = Depends(get_db),
    x_actor: str = Header(default="unknown"),
):
    policy = db.get(Policy, policy_id)
    if policy is None:
        raise HTTPException(status_code=404, detail="policy not found")

    before = _snapshot(policy)
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(policy, field, value)
    db.flush()

    db.add(
        AuditLog(
            policy_id=policy.id,
            action="update",
            actor=x_actor,
            before=json.dumps(before),
            after=json.dumps(_snapshot(policy)),
        )
    )
    db.commit()
    db.refresh(policy)
    return policy
