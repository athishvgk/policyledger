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
# note in ensure_schema() below. Any int64 works; it just has to be the same
# constant every time this app starts.
_SCHEMA_LOCK_ID = 727271


def ensure_schema(eng) -> None:
    """Create the tables if they're missing; safe when replicas start together.

    A real system would use migrations (e.g. Alembic) so schema changes are
    reviewable and reversible; this is a synthetic registry, so create_all
    keeps every file easy to explain.

    With 2 replicas both pods run this at once: both check "does `policies`
    exist?", both see no, both issue CREATE TABLE, and one crashes on a
    duplicate-table error. A Postgres advisory lock serializes that
    check-then-create so only one replica does it at a time.

    The lock must be transaction-scoped (pg_advisory_xact_lock), which
    Postgres releases itself at COMMIT. An earlier version took a session
    lock and unlocked it by hand *before* the commit: in that sliver of time
    the next replica got the lock, could not yet see the first replica's
    uncommitted table, and crashed with DuplicateTable. It hit about 1 start
    in 400 with two replicas, and showed up on the first AKS deploy.

    SQLite (used by the test suite) has no advisory locks and never runs more
    than one process against one database, so it goes straight to create_all.
    """
    if eng.dialect.name == "postgresql":
        with eng.begin() as conn:
            conn.execute(text("SELECT pg_advisory_xact_lock(:lock_id)"), {"lock_id": _SCHEMA_LOCK_ID})
            Base.metadata.create_all(bind=conn)
    else:
        Base.metadata.create_all(bind=eng)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Runs at startup (not import time) so tests can swap in a different
    # engine first -- which is why `engine` is looked up here, at call time.
    ensure_schema(engine)
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
